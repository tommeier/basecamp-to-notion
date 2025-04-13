# utils/media_extractor/resolver.rb

require 'uri'
require 'open-uri'
require_relative './constants'
require_relative './logger'

module Utils
  module MediaExtractor
    module Resolver
      extend ::Utils::Logging

      @resolved_url_cache = {}

      def self.resolve_basecamp_url(url, context = nil)
        return @resolved_url_cache[url] if @resolved_url_cache.key?(url)

        original_url = extract_original_url_from_basecamp_proxy(url)
        if original_url
          @resolved_url_cache[url] = original_url
          return original_url
        end

        begin
          request_headers = basecamp_cdn_url?(url) ? {} : (Utils::MediaExtractor.basecamp_headers || {})
          URI.open(url, request_headers) do |file|
            final_url = file.base_uri.to_s rescue url
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
        uri = URI(basecamp_url)
        return unless uri.query

        params = URI.decode_www_form(uri.query).to_h
        original_url = params['u'] || params['url']
        original_url if original_url&.match?(URI.regexp(%w[http https]))
      end

      def self.embeddable_media_url?(url)
        url.match?(/(giphy\.com|youtube\.com|vimeo\.com|instagram\.com|twitter\.com)/)
      end

      def self.basecamp_asset_url?(url)
        url.match?(/(basecampusercontent\.com|basecamp-static\.com|preview\.3\.basecamp\.com|storage\.3\.basecamp\.com)/)
      end

      def self.basecamp_cdn_url?(url)
        url.match?(/(basecamp-static\.com|bc3-production-assets-cdn\.basecamp-static\.com)/)
      end
    end
  end
end
