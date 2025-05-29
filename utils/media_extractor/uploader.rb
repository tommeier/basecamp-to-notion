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

module Utils
  module MediaExtractor
    module Uploader
      extend Resolver
      extend Utils::Dependencies
      module_function

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
        URI.open(url, 'rb')
      rescue OpenURI::HTTPError, Errno::ENOENT
        nil
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
