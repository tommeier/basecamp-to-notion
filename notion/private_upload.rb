# notion/private_upload.rb
#
# Experimental helper to upload files to Notion via its private, undocumented API.
# This allows us to host formerly time-limited Basecamp assets (e.g. CloudFront/S3
# proxy URLs) on Notion's own S3 bucket so they remain permanently accessible.
#
# ⚠️  This relies on the `token_v2` cookie from a logged-in Notion user.
#     Provide it via environment variable `NOTION_TOKEN_V2`.
#     If the env var is missing, the helper is disabled and will return nil.
#
# The upload flow replicates the Notion web client:
#   1.  POST /api/v3/getUploadFileUrl  →  receives a signed PUT URL.
#   2.  HTTP PUT the file bytes to S3.
#   3.  (Optional) POST /api/v3/completeUpload to finalise.
#
# On success, the helper returns the public `signedGetUrl` that can be used in
# an `external` image / file block.
#
# If any step fails the helper logs a warning and returns nil so that callers
# can gracefully fall back to the existing Basecamp asset call-out blocks.

require 'net/http'
require 'uri'
require 'json'
require 'tempfile'
require 'open-uri'
require_relative './auth'
require_relative '../utils/logging'
require_relative '../utils/http'
require_relative '../utils/media_extractor/helpers'
require_relative '../utils/http'
require_relative '../utils/google_session'
require 'digest/sha1'
require 'digest/md5'
require 'securerandom'

module Notion
  module PrivateUpload
    extend ::Utils::Logging

    NOTION_ORIGIN = ENV.fetch('NOTION_ORIGIN', 'https://www.notion.so').freeze

    # Default browser-like user agent to improve compatibility when downloading
    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                         'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15'.freeze

    # Map common MIME types to reasonable file extensions for Notion uploads
    EXT_FOR_MIME = {
      'image/jpeg'         => '.jpg',
      'image/png'          => '.png',
      'image/gif'          => '.gif',
      'image/webp'         => '.webp',
      'application/pdf'    => '.pdf',
      'video/mp4'          => '.mp4',
      'video/quicktime'    => '.mov',
      'application/octet-stream' => '.bin'
    }.freeze

    # Timeouts (seconds) for downloading remote resources. Can be tuned via ENV at runtime.
    OPEN_TIMEOUT  = (ENV.fetch('PRIVATE_UPLOAD_OPEN_TIMEOUT', 15)).to_i  # TCP connection setup
    READ_TIMEOUT  = (ENV.fetch('PRIVATE_UPLOAD_READ_TIMEOUT', 120)).to_i # Full body read

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------
    @notion_token_checked = false
    def self.enabled?
      enabled = !token.nil? && !token.empty?
      unless @notion_token_checked
        if enabled
          log "✅ [PrivateUpload] Notion token is available and enabled"
        else
          warn "⚠️  [PrivateUpload] Disabled — NOTION_TOKEN_V2 environment variable not set"
        end
        @notion_token_checked = true
      end
      enabled
    end

    # Downloads + uploads the resource at +src_url+.
    # Returns a permanent Notion-hosted URL or nil on failure.
    def self.upload_from_url(src_url, context = nil)
      return nil unless enabled?
      log "📤 [PrivateUpload] Attempting upload from #{src_url} (#{context})"

      begin
        io, filename, mime = download_to_io(src_url)
        return nil unless io

        # Compute size (bytes) and MD5 digest (Base64) for Notion validation
        io.rewind
        io.flush
        size_bytes = io.size
        md5_b64    = size_bytes.zero? ? nil : Digest::MD5.file(io.path).base64digest

        if size_bytes.zero?
          warn "⚠️  [PrivateUpload] Skipping upload — downloaded file is zero bytes (#{context})"
          return nil
        end

        upload_url_info = get_upload_url(filename, mime, size_bytes, md5_b64, context)
        return nil unless upload_url_info && upload_url_info['url']

        unless put_to_s3(upload_url_info['url'], io, mime, context)
          warn "⚠️  [PrivateUpload] PUT to S3 failed (#{context})"
          return nil
        end

        # Some responses already contain a signedGetUrl we can use directly.
        # If not, try to complete the upload (older API flow).
        signed_url = upload_url_info['signedGetUrl']
        if signed_url.nil? || signed_url.strip.empty?
          signed_url = complete_upload(upload_url_info, context)
        end

        if signed_url && !signed_url.empty?
          log "✅ [PrivateUpload] Upload successful — #{signed_url} (#{context})"
          signed_url
        else
          warn "⚠️  [PrivateUpload] No signed URL returned (#{context})"
          nil
        end
      rescue => e
        warn "⚠️  [PrivateUpload] Exception during upload: #{e.class}: #{e.message} (#{context})"
        nil
      ensure
        io&.close!
      end
    end

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def self.token
      # Try ENV first, otherwise fall back to interactive auth helper
      ENV['NOTION_TOKEN_V2'] || (defined?(::Notion::Auth) ? ::Notion::Auth.token : nil)
    end

    # Attempts to download +src_url+ to a Tempfile.
    # Adds a browser-like User-Agent header and retries once with additional
    # headers if the first attempt returns 403 (common with googleusercontent).
    def self.download_to_io(src_url)
      uri = URI.parse(src_url)
      filename = File.basename(uri.path)
      mime = ::Utils::MediaExtractor::Helpers.mime_type_for(filename)
      # Ensure the filename has an extension; Notion API rejects names without one.
      if File.extname(filename).empty?
        default_ext = EXT_FOR_MIME.fetch(mime, '.bin')
        filename = "#{filename}#{default_ext}"
        # Recompute MIME if it was generic
        mime = guess_mime_type(filename) if mime == 'application/octet-stream'
      end

      # Sanitize filename for Notion: ASCII only, remove leading symbols, max length.
      filename = filename.gsub(/[^A-Za-z0-9_.-]/, '-')
      filename = filename.sub(/\A[^A-Za-z0-9]+/, '')
      if filename.length > 100
        base = File.basename(filename, '.*')[0, 80]
        filename = "#{base}#{File.extname(filename)}"
      end

      # If filename still looks like a long hash (no vowels, mostly hex), replace with friendly one
      if filename.gsub(/[^a-f0-9]/i, '').length > 24 && filename.length > 30
        filename = "image_#{SecureRandom.hex(4)}#{File.extname(filename)}"
      end

      # Fallback: if MIME still generic, assume jpeg (most common) and adjust name/ext
      if mime == 'application/octet-stream'
        mime = 'image/jpeg'
        filename = File.basename(filename, '.*') + '.jpg'
      end

      max_retries = 3
      base_delay = 1.0 # seconds
      attempt = 0
      tmp = nil

      begin
        tmp = Tempfile.new(['upload', File.extname(filename)])
        tmp.binmode
        base_headers = (::Utils::MediaExtractor.basecamp_headers || {}).dup

        # If the source is a Google private asset, include authenticated cookies
        if uri.host.include?('googleusercontent.com')
          ::Utils::GoogleSession.ensure_cookies!
          if (cookie = ::Utils::GoogleSession.cookie_header)
            base_headers['Cookie'] = cookie
            sapisid = cookie.split(';').map(&:strip).find { |c| c.start_with?('SAPISID=') }&.split('=', 2)&.last
            if sapisid
              origin = "#{uri.scheme}://#{uri.host}"
              ts = Time.now.to_i
              hash = Digest::SHA1.hexdigest("#{ts} #{sapisid} #{origin}")
              base_headers['Authorization'] = "SAPISIDHASH #{ts}_#{hash}"
              base_headers['x-goog-authuser'] = '0'
              base_headers['X-Origin'] = origin
            end
          end
        end
        base_headers['User-Agent'] ||= DEFAULT_USER_AGENT
        base_headers['Accept'] ||= '*/*'

        begin
          while attempt < max_retries
            attempt += 1
            log "🌐 [PrivateUpload] Downloading (attempt #{attempt}) #{src_url} — timeouts: open=#{OPEN_TIMEOUT}s, read=#{READ_TIMEOUT}s"
            begin
              # Use Net::HTTP for full timeout and header control
              # Follow redirects up to 5 times
              max_redirects = 5
              current_url = src_url
              redirect_count = 0
              headers = base_headers.dup
              begin
                uri_obj = URI.parse(current_url)
                Net::HTTP.start(uri_obj.host, uri_obj.port, use_ssl: uri_obj.scheme == 'https',
                                open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
                  req = Net::HTTP::Get.new(uri_obj)
                  headers.each { |k, v| req[k] = v }
                  http.request(req) do |resp|
                    case resp
                    when Net::HTTPSuccess
                      # Refine MIME type using HTTP response header
                      header_ct = resp['content-type']&.split(';')&.first&.strip
                      if header_ct && !header_ct.empty? && header_ct != 'application/octet-stream'
                        mime = header_ct
                        if File.extname(filename).empty?
                          filename += EXT_FOR_MIME.fetch(mime, '.bin')
                        end
                      end
                      resp.read_body { |chunk| tmp.write(chunk) }
                      tmp.flush
                      if tmp.size.zero?
                        # Fallback: try open-uri read
                        open_opts = headers.merge('User-Agent' => base_headers['User-Agent'],
                                                   open_timeout: OPEN_TIMEOUT,
                                                   read_timeout: READ_TIMEOUT)
                        ::URI.open(current_url, open_opts) do |io_src|
                          IO.copy_stream(io_src, tmp)
                        end
                        raise RuntimeError, 'Downloaded zero bytes' if tmp.size.zero?
                      end
                    when Net::HTTPRedirection
                      redirect_count += 1
                      raise "Too many redirects" if redirect_count > max_redirects
                      current_url = resp['location'] || resp['Location']
                      log "🔀 [PrivateUpload] Following redirect to #{current_url}"
                      next # retry with new URL
                    else
                      raise OpenURI::HTTPError.new(resp.message, resp)
                    end
                  end
                end
              rescue OpenURI::HTTPError => e
                # Pass error up to retry logic
                raise e
              end
              if tmp.size.zero?
                # Fallback download via open-uri once
                open_opts = headers.merge('User-Agent' => base_headers['User-Agent'],
                                           open_timeout: OPEN_TIMEOUT,
                                           read_timeout: READ_TIMEOUT)
                ::URI.open(current_url, open_opts) do |io_src|
                  IO.copy_stream(io_src, tmp)
                end
                raise RuntimeError, 'Downloaded zero bytes' if tmp.size.zero?
              end
              log "✅ [PrivateUpload] Download successful without extra headers (#{src_url})"
              break # Success, exit retry loop
            rescue OpenURI::HTTPError => e
              # Only retry 403 once, as before
              if e.io&.code == '403' && attempt == 1
                extra_headers = base_headers.merge(
                  'Accept'  => '*/*',
                  'Referer' => "https://#{uri.host}/",
                  'x-goog-authuser' => '0',
                  'X-Origin' => "https://#{uri.host}"
                )
                log "🔄 [PrivateUpload] Retry download with browser headers due to 403 (#{src_url})"
                begin
                  # Use Net::HTTP for full timeout and header control (retry with extra_headers)
                  # Follow redirects up to 5 times for retry
                  max_redirects = 5
                  current_url = src_url
                  redirect_count = 0
                  headers = extra_headers.dup
                  begin
                    uri_obj = URI.parse(current_url)
                    Net::HTTP.start(uri_obj.host, uri_obj.port, use_ssl: uri_obj.scheme == 'https',
                                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
                      req = Net::HTTP::Get.new(uri_obj)
                      headers.each { |k, v| req[k] = v }
                      http.request(req) do |resp|
                        case resp
                        when Net::HTTPSuccess
                          # Refine MIME using retry response
                          header_ct = resp['content-type']&.split(';')&.first&.strip
                          if header_ct && !header_ct.empty? && header_ct != 'application/octet-stream'
                            mime = header_ct
                            if File.extname(filename).empty?
                              filename += EXT_FOR_MIME.fetch(mime, '.bin')
                            end
                          end
                          resp.read_body { |chunk| tmp.write(chunk) }
                          tmp.flush
                          if tmp.size.zero?
                            open_opts = headers.merge('User-Agent' => base_headers['User-Agent'],
                                                       open_timeout: OPEN_TIMEOUT,
                                                       read_timeout: READ_TIMEOUT)
                            ::URI.open(current_url, open_opts) do |io_src|
                              IO.copy_stream(io_src, tmp)
                            end
                            raise RuntimeError, 'Downloaded zero bytes' if tmp.size.zero?
                          end
                        when Net::HTTPRedirection
                          redirect_count += 1
                          raise "Too many redirects" if redirect_count > max_redirects
                          current_url = resp['location'] || resp['Location']
                          log "🔀 [PrivateUpload] Following redirect to #{current_url}"
                          next # retry with new URL
                        else
                          raise OpenURI::HTTPError.new(resp.message, resp)
                        end
                      end
                    end
                  rescue OpenURI::HTTPError => e
                    # Pass error up to retry logic
                    raise e
                  end
                  log "✅ [PrivateUpload] Download successful with browser headers (#{src_url})"
                  break # Success, exit retry loop
                rescue OpenURI::HTTPError => e2
                  if e2.io&.code == '403'
                    warn "⚠️  [PrivateUpload] Download failed with browser headers (403) for #{src_url}"
                    raise # Don't retry further on 403
                  else
                    raise
                  end
                end
              else
                raise
              end
            rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT, RuntimeError => e
              if attempt < max_retries
                delay = base_delay * (2 ** (attempt - 1))
                jitter = SecureRandom.random_number(delay / 2.0)
                total_delay = delay + jitter
                warn "⏳ [PrivateUpload] Timeout/network error on attempt #{attempt} for #{src_url}: #{e.class} - #{e.message}. Retrying in #{'%.2f' % total_delay}s..."
                sleep(total_delay)
                tmp.truncate(0)
                tmp.rewind
                next
              else
                warn "❌ [PrivateUpload] Giving up after #{attempt} attempts for #{src_url}: #{e.class} - #{e.message}"
                raise
              end
            end
          end
        end
        tmp.rewind
        tmp.flush
        log "✅ [PrivateUpload] Final download result for #{src_url}: #{tmp.size} bytes after #{attempt} attempts"
        [tmp, filename, mime]
      rescue => e
        warn "⚠️  [PrivateUpload] Download failed for #{src_url}: #{e.message}"
        tmp&.close!
        [nil, nil, nil]
      end
    end

    def self.get_upload_url(filename, mime, size, md5, context)
      payload = {
        bucket: 'secure',
        name: filename,
        contentType: mime
      }
      payload[:size] = size unless size.nil? || size.zero?
      payload[:md5]  = md5  unless md5.nil? || md5.empty?
      headers = notion_headers
      ::Utils::HTTP.request_json(:post, "#{NOTION_ORIGIN}/api/v3/getUploadFileUrl", payload, headers, context: context)
    rescue => e
      warn "⚠️  [PrivateUpload] getUploadFileUrl failed: #{e.message} (#{context})"
      nil
    end

    def self.put_to_s3(put_url, io, mime, context)
      uri = URI.parse(put_url)
      req = Net::HTTP::Put.new(uri)
      req['Content-Type'] = mime
      io.rewind
      req.body = io.read

      Net::HTTP.start(uri.host, uri.port, use_ssl: (uri.scheme == 'https')) do |http|
        res = http.request(req)
        unless res.code.to_i.between?(200, 299)
          warn "⚠️  [PrivateUpload] PUT returned #{res.code} (#{context})"
          return false
        end
      end
      true
    rescue => e
      warn "⚠️  [PrivateUpload] PUT exception: #{e.message} (#{context})"
      false
    end

    def self.complete_upload(upload_info, context)
      payload = {
        bucket: upload_info['bucket'] || 'secure',
        key:    upload_info['path']   || upload_info['key']
      }
      headers = notion_headers
      res = ::Utils::HTTP.request_json(:post, "#{NOTION_ORIGIN}/api/v3/completeUpload", payload, headers, context: context)
      res['signedGetUrl'] if res.is_a?(Hash)
    rescue => e
      warn "⚠️  [PrivateUpload] completeUpload failed: #{e.message} (#{context})"
      nil
    end

    def self.notion_headers
      {
        'Content-Type' => 'application/json',
        'Cookie'       => "token_v2=#{token}",
        'User-Agent'   => 'NotionPrivateUploader/1.0'
      }
    end

    def self.guess_mime_type(filename)
      ext = File.extname(filename).downcase
      case ext
      when '.png'  then 'image/png'
      when '.jpg', '.jpeg' then 'image/jpeg'
      when '.gif'  then 'image/gif'
      when '.webp' then 'image/webp'
      when '.pdf'  then 'application/pdf'
      when '.mp4'  then 'video/mp4'
      when '.mov'  then 'video/quicktime'
      else 'application/octet-stream'
      end
    end
  end
end
