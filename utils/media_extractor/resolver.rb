# utils/media_extractor/resolver.rb

require 'uri'
require 'open-uri'
require 'net/http'
require 'json'
require_relative './constants'
require_relative './logger'
require_relative './../../utils/basecamp_session'
require_relative './../../utils/google_session'

module Utils
  module MediaExtractor
    module Resolver
      extend ::Utils::Logging

      @resolved_url_cache = {}

      # Prompt for Google and Basecamp sessions at startup
      def self.ensure_sessions_at_startup!
        Utils::BasecampSession.ensure_cookies!
        Utils::GoogleSession.ensure_cookies!
      end

      def self.resolve_basecamp_url(url, context = nil)
        return @resolved_url_cache[url] if @resolved_url_cache.key?(url)
        unless url.is_a?(String) && url.strip.match?(URI::DEFAULT_PARSER.make_regexp)
          error "❌ [resolve_basecamp_url] Invalid input, not a URL: #{url.inspect} (#{context})"
          return nil
        end

        original_url = extract_original_url_from_basecamp_proxy(url)
        if original_url
          @resolved_url_cache[url] = original_url
          return original_url
        end

        # Special case: private preview/storage URLs – first try direct fetch with cookies
        if basecamp_asset_url?(url) && Utils::MediaExtractor.basecamp_headers
          begin
            URI.open(url, Utils::MediaExtractor.basecamp_headers) do |file|
              final = file.base_uri.to_s rescue url
              unless basecamp_asset_url?(final)
                log "✅ [resolve_basecamp_url] Direct cookie fetch resolved => #{final} (#{context})"
                @resolved_url_cache[url] = final
                return final
              end
            end
          rescue => e
            log "⚠️ Direct cookie fetch failed: #{e.class}: #{e.message} (#{context})"
          end

          # Fallback: reuse existing browser session to follow redirects
          if (resolved = try_browser_resolve(url, context))
            @resolved_url_cache[url] = resolved
            return resolved
          end
        end

        begin
          request_headers = basecamp_cdn_url?(url) ? {} : (Utils::MediaExtractor.basecamp_headers || {})
          URI.open(url, request_headers) do |file|
            final_url = file.base_uri.to_s rescue url

            # If we still ended up on a private preview/storage host, try browser resolve once more
            if basecamp_asset_url?(final_url) && (resolved = try_browser_resolve(final_url, context))
              @resolved_url_cache[url] = resolved
              return resolved
            end

            log "✅ [resolve_basecamp_url] Resolved: #{final_url} (#{context})"
            @resolved_url_cache[url] = final_url
            return final_url
          end
        rescue => e
          error "❌ [resolve_basecamp_url] Failed to resolve: #{url} (#{context}) — #{e.message}"
          @resolved_url_cache[url] = nil
          nil
        end
      end

      def self.extract_original_url_from_basecamp_proxy(basecamp_url)
        return unless basecamp_url.is_a?(String) && basecamp_url.strip != ""

        uri = URI(basecamp_url)
        return unless uri.query

        params = URI.decode_www_form(uri.query).to_h
        original_url = params['u'] || params['url']
        original_url if original_url&.match?(URI.regexp(%w[http https]))
      rescue URI::InvalidURIError => e
        error "❌ [extract_original_url_from_basecamp_proxy] Invalid URI: #{basecamp_url.inspect} — #{e.message}"
        nil
      end

      def self.embeddable_media_url?(url)
        url.match?(/(giphy\.com|youtube\.com|vimeo\.com|instagram\.com|twitter\.com|loom\.com|figma\.com|miro\.com)/)
      end

      def self.basecamp_asset_url?(url)
        # Returns true if the URL is expected to require authentication (ie. Notion cannot fetch it unauthenticated)
        # We intentionally EXCLUDE the CDN domains which are already public (basecamp-static.com, bc3-production-assets-cdn.*)
        # and S3 proxy hosts (basecampusercontent.com) which are usually signed, time-limited, but publicly readable.
        # Only the preview/storage sub-domains tend to be strictly cookie-protected.
        url.match?(/\b(preview\.3\.basecamp\.com|storage\.3\.basecamp\.com)\b/)
      end

      def self.basecamp_cdn_url?(url)
        url.match?(/(basecamp-static\.com|bc3-production-assets-cdn\.basecamp-static\.com)/)
      end

      # ----------------------------
      # Helper: use existing Selenium session to follow redirects
      # ----------------------------
      def self.try_browser_resolve(private_url, context)
        log "🔍 [try_browser_resolve] Using browser session for #{private_url} (#{context})"
        begin
          if private_url.include?("googleusercontent.com")
            Utils::GoogleSession.ensure_cookies!
            driver = Utils::GoogleSession.driver
          else
            Utils::BasecampSession.ensure_cookies!
            driver = Utils::BasecampSession.driver
          end
          return nil unless driver

          driver.navigate.to(private_url)
          Selenium::WebDriver::Wait.new(timeout: 20).until { driver.current_url != private_url }
          final = driver.current_url
          if final && final.match?(URI::DEFAULT_PARSER.make_regexp)
            # For basecamp assets, only return if not a basecamp asset. For google, always return if changed.
            if private_url.include?("googleusercontent.com") || !basecamp_asset_url?(final)
              log "✅ [try_browser_resolve] Browser redirect => #{final} (#{context})"
              return final
            end
          end
        rescue => e
          warn "⚠️ [try_browser_resolve] Failed for #{private_url}: #{e.class}: #{e.message} (#{context})"
        end
        nil
      end
    end
  end
end
