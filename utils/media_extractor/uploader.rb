# frozen_string_literal: true
#
# Decides whether to keep a URL as‑is or to fetch it privately and
# re‑upload it to Notion (via the official Notion API).
#
require 'open-uri'
require 'tempfile'
require 'uri'
require_relative '../../notion/uploads' # For Notion::Uploads::FileUpload

require_relative '../../basecamp/fetch'
require_relative '../dependencies'
require_relative './resolver'                  # embeddable?, preview_url_for …
require_relative '../../utils/browser_capture' # in‑browser pixel capture
require_relative '../retry_utils'
require_relative '../logging' # For logging

module Utils
  module MediaExtractor
    module Uploader
      extend Resolver
      extend Utils::Dependencies
      extend ::Utils::Logging # Add logging
      module_function

      # Retry parameters for Google downloads
      GOOGLE_DOWNLOAD_MAX_RETRIES = ENV.fetch('GOOGLE_DOWNLOAD_MAX_RETRIES', 3).to_i
      GOOGLE_DOWNLOAD_INITIAL_DELAY_SECONDS = ENV.fetch('GOOGLE_DOWNLOAD_INITIAL_DELAY_SECONDS', 1.5).to_f
      GOOGLE_DOWNLOAD_MAX_DELAY_SECONDS = ENV.fetch('GOOGLE_DOWNLOAD_MAX_DELAY_SECONDS', 15.0).to_f
      GOOGLE_DOWNLOAD_MULTIPLIER = ENV.fetch('GOOGLE_DOWNLOAD_MULTIPLIER', 2.0).to_f
      # Add 403 as Google sometimes throws this transiently for high volume
      RETRIABLE_HTTP_STATUSES = [403, 429, 500, 502, 503, 504].freeze
      # Common transient network errors
      TRANSIENT_NETWORK_ERRORS = [
        Errno::ECONNRESET,
        Errno::ECONNABORTED,
        Errno::EPIPE,
        Errno::ETIMEDOUT,
        Net::OpenTimeout,
        Net::ReadTimeout,
        SocketError
      ].freeze

      # ------------------------------------------------------------------
      # Download strategies (anon → API → cookie → browser)
      # ------------------------------------------------------------------
      def download_with_auth(url, context)
        # NOTE: at this point `url` is already the public CloudFront/S3 link if one existed

        stream_obj = try_simple(url)
        return [stream_obj, stream_obj.content_type] if stream_obj

        if (stream_obj = api_fetch(url))
          tmp = cache_stream(stream_obj, 'bc_api')
          return [tmp, stream_obj.content_type || 'application/octet-stream']
        end

        if (pair = cookie_fetch_with_preview(url, context))
          return pair
        end

        if (driver = Utils::BasecampSession.driver)
          if (pair = Utils::BrowserCapture.fetch(url, driver))
            return pair
          end
        end

        # 4) last‑ditch: if Resolver gave us a public URL we *still* couldn’t stream
        #    try one more plain GET (covers very rare TLS redirects)
        begin
          stream_obj = URI.open(url, 'rb')
          return [stream_obj, stream_obj.content_type] if stream_obj
        rescue OpenURI::HTTPError, Errno::ENOENT
        end

        warn "⚠️  [Uploader] Download failed (#{context})"
        nil
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------
      def try_simple(url)
        is_google_url = url.include?('googleusercontent.com') || url.include?('usercontent.google.com')

        if is_google_url
          current_delay = GOOGLE_DOWNLOAD_INITIAL_DELAY_SECONDS
          (1..GOOGLE_DOWNLOAD_MAX_RETRIES).each do |attempt|
            begin
              log "[Uploader.try_simple] Attempt ##{attempt} to download Google URL: #{url}"
              # Set read_timeout for URI.open to avoid indefinite hangs
              io = URI.open(url, 'rb', read_timeout: 30) # 30 seconds timeout
              log "[Uploader.try_simple] Successfully downloaded Google URL: #{url} on attempt ##{attempt}"
              return io
            rescue OpenURI::HTTPError => e
              status_code = e.io.status[0].to_i
              log_msg = "[Uploader.try_simple] Google URL download attempt ##{attempt} failed for #{url}. HTTP Status: #{status_code}. Error: #{e.message}"
              if RETRIABLE_HTTP_STATUSES.include?(status_code)
                warn log_msg
                if attempt == GOOGLE_DOWNLOAD_MAX_RETRIES
                  error "[Uploader.try_simple] Max retries (#{GOOGLE_DOWNLOAD_MAX_RETRIES}) reached for Google URL #{url}. Last error: #{e.message}"
                  return nil
                end
              else # Non-retriable HTTP error
                error "[Uploader.try_simple] Non-retriable HTTP error for Google URL #{url} on attempt ##{attempt}: #{status_code}. Error: #{e.message}"
                return nil
              end
            rescue *TRANSIENT_NETWORK_ERRORS => e
              log_msg = "[Uploader.try_simple] Google URL download attempt ##{attempt} failed for #{url} with network error: #{e.class} - #{e.message}"
              warn log_msg
              if attempt == GOOGLE_DOWNLOAD_MAX_RETRIES
                error "[Uploader.try_simple] Max retries (#{GOOGLE_DOWNLOAD_MAX_RETRIES}) reached for Google URL #{url} due to network errors. Last error: #{e.message}"
                return nil
              end
            rescue StandardError => e # Catch any other unexpected errors
              error "[Uploader.try_simple] Unexpected error during Google URL download attempt ##{attempt} for #{url}: #{e.class} - #{e.message}"
              # For unexpected errors, probably best not to retry endlessly without understanding them.
              return nil if attempt == GOOGLE_DOWNLOAD_MAX_RETRIES # Or simply return nil / re-raise earlier.
            end

            # If we are here, it means a retriable error occurred and it's not the last attempt
            sleep_duration = Utils::RetryUtils.calculate_jittered_sleep(current_delay)
            log "[Uploader.try_simple] Sleeping for #{'%.2f' % sleep_duration}s before next attempt for Google URL #{url}"
            sleep(sleep_duration)
            current_delay = [current_delay * GOOGLE_DOWNLOAD_MULTIPLIER, GOOGLE_DOWNLOAD_MAX_DELAY_SECONDS].min
          end
          # If loop finishes, all retries failed for Google URL
          error "[Uploader.try_simple] All #{GOOGLE_DOWNLOAD_MAX_RETRIES} download attempts failed for Google URL: #{url}"
          nil
        else # Not a Google URL, use original simple fetch
          begin
            URI.open(url, 'rb', read_timeout: 30)
          rescue OpenURI::HTTPError, Errno::ENOENT, StandardError => e # Added StandardError for broader catch on non-Google URLs too
            warn "[Uploader.try_simple] Failed to download non-Google URL #{url}: #{e.class} - #{e.message}"
            nil
          end
        end
      end

      def api_fetch(url)
        Basecamp::Fetch.download_with_auth(url)
      rescue
        nil
      end

      def cookie_fetch_with_preview(url, context)
        hdrs = Utils::MediaExtractor.basecamp_headers or return nil
        [url, Resolver.preview_url_for(url)].compact.each_with_index do |target, idx|
          begin
            io  = URI.open(target, hdrs.merge('rb'))
            tmp = cache_stream(io, idx.zero? ? 'bc_cookie' : 'bc_preview')
            return [tmp, io.content_type || 'application/octet-stream']
          rescue OpenURI::HTTPError => e
            raise unless e.io.status.first == '404' && idx.zero?
            log "🔍 storage 404 → preview fallback (#{context})"
          end
        end
        nil
      end

      # Copy IO → Tempfile and rewind
      def cache_stream(io, prefix)
        Tempfile.new([prefix, File.extname(io.base_uri.path)]).tap do |t|
          t.binmode
          IO.copy_stream(io, t)
          t.rewind
        end
      end
    end
  end
end
