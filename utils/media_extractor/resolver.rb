# frozen_string_literal: true
#
# Turns Basecamp “storage/preview” URLs (and Google Blob URLs) into
# publicly‑fetchable variants.  Falls back to a headless Chrome
# session when cookies or redirects are required.
#
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

      # ------------------------------------------------------------------
      # Helpers – detect & build preview URLs for expired storage links
      # ------------------------------------------------------------------
      DOWNLOAD_RE = %r{\Ahttps://storage\.3\.basecamp\.com/
                       (?<acct>\d+)/blobs/(?<uuid>[0-9a-f-]+)/
                       download/[^/?]+}xi.freeze

      def self.preview_url_for(download_url)
        m = DOWNLOAD_RE.match(download_url)
        return nil unless m

        "https://preview.3.basecamp.com/#{m[:acct]}/blobs/#{m[:uuid]}/previews/full"
      end

      CLOUDFRONT_RE = %r{\Ahttps://.+\.cloudfront\.net/}i.freeze

      def self.still_private_asset?(url)
        url.nil? ||
          basecamp_asset_url?(url) ||            # storage|preview hosts
          url.match?(CLOUDFRONT_RE)              # signed CloudFront redirect
      end

      # ------------------------------------------------------------------
      @resolved_url_cache = {}
      @@missing_attachments = {}   # 404/410 cache so we skip next time

      # Prompt for sessions as early as possible (boot hook calls this)
      def self.ensure_sessions_at_startup!
        log "💻 [Resolver] Starting Basecamp browser session..."
        Utils::BasecampSession.ensure_cookies!

        log "💻 [Resolver] Starting Google browser session..."
        Utils::GoogleSession.ensure_cookies!

        log "🔍 [Resolver] Browser sessions ready: "\
            "Basecamp=#{!!Utils::BasecampSession.driver}, "\
            "Google=#{!!Utils::GoogleSession.driver}"
      end

      # ------------------------------------------------------------------
      # MAIN – attempts a series of increasingly heavy strategies
      # ------------------------------------------------------------------
      def self.resolve_basecamp_url(url, context = nil)
        return nil                            if @@missing_attachments[url]
        return @resolved_url_cache[url]       if @resolved_url_cache.key?(url)

        unless url.is_a?(String) && url =~ URI::DEFAULT_PARSER.make_regexp
          error "❌ [resolve_basecamp_url] Not a URL: #{url.inspect} (#{context})"
          return nil
        end

        # A. Proxy wrapper? (…/redirect?u=<orig>)
        if (orig = extract_original_url_from_basecamp_proxy(url))
          return @resolved_url_cache[url] = orig
        end

        # B. Quick HEAD check for now‑deleted attachments
        begin
          uri = URI(url)
          if uri.path =~ /\/attachments\/(\d+)/
            attach_id = Regexp.last_match(1)
            headers   = Utils::MediaExtractor.basecamp_headers || {}
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
              res = http.request(Net::HTTP::Head.new(uri, headers))
              if [404, 410].include?(res.code.to_i)
                account_id = uri.path.split('/')[1]
                json_url   = "https://3.basecampapi.com/#{account_id}/attachments/#{attach_id}.json"
                log "🔄 404 → trying JSON API #{json_url} (#{context})"
                begin
                  json = URI.open(json_url, headers) { |io| JSON.parse(io.read) }
                  if (dl = json['download_url'])
                    log "✅ JSON API gave #{dl} (#{context})"
                    return @resolved_url_cache[url] = dl
                  end
                rescue => e
                  warn "⚠️  JSON API failed: #{e.class}: #{e.message} (#{context})"
                end
                warn "🚫 Attachment missing: #{url} (#{context})"
                @@missing_attachments[url] = true
                return nil
              end
            end
          end
        rescue => e
          warn "⚠️  HEAD check failed: #{e.class}: #{e.message} (#{context})"
        end

        # C. For any private Basecamp asset (storage/preview hosts), **always**
        #    use the headless‑browser flow.  No more cookie‑driven `open-uri`
        #    fetches – they are brittle and leak cookies in multi‑threaded
        #    jobs.  The browser session already has the right cookies loaded,
        #    so let it do the heavy lifting.
        if basecamp_asset_url?(url)
          if (resolved = try_browser_resolve(url, context))
            return @resolved_url_cache[url] = resolved
          end
          warn "🚫 Browser failed to resolve #{url} (#{context})"
          @resolved_url_cache[url] = nil
          return nil
        end

        # D. Plain open – handles already‑public CDN links or non‑Basecamp URLs
        begin
          hdrs = basecamp_cdn_url?(url) ? {} : (Utils::MediaExtractor.basecamp_headers || {})
          URI.open(url, hdrs) do |f|
            final = f.base_uri.to_s rescue url
            log "✅ Resolved: #{final} (#{context})"
            return @resolved_url_cache[url] = final
          end
        rescue => e
          error "❌ Could not resolve #{url} (#{context}) — #{e.message}"
          @resolved_url_cache[url] = nil
          nil
        end
      end

      # ------------------------------------------------------------------
      # try_browser_resolve – **unchanged**
      # ------------------------------------------------------------------
      def self.try_browser_resolve(private_url, context)
        log "🔍 [try_browser_resolve] Using browser session for #{private_url} (#{context})"
        begin
          is_google_url = private_url.include?("googleusercontent.com") ||
                          private_url.include?("usercontent.google.com")

          if is_google_url
            # GoogleSession handles its own synchronization internally for driver access and navigation
            # The driver method ensures cookies and returns an initialized driver.
            driver = Utils::GoogleSession.driver
            return nil unless driver

            # Special handling for Google 403 loops
            max_retries   = 3
            retries       = 0
            random_sleep  = -> { sleep(1 + rand * 2) }

            while retries < max_retries
              random_sleep[]
              # navigate_to is synchronized internally in GoogleSession
              unless Utils::GoogleSession.navigate_to(private_url)
                warn "⚠️  Google navigate failed (attempt #{retries + 1})"
                return nil if (retries += 1) >= max_retries
                next
              end

              if driver.page_source.include?("403. That's an error") ||
                 driver.page_source.include?("Your client does not have permission")
                warn "⚠️  Google 403 detected (attempt #{retries + 1})"
                return nil if (retries += 1) >= max_retries
              else
                break
              end
            end
            # Wait up to 20s for a redirect (specific to Google flow here)
            Selenium::WebDriver::Wait.new(timeout: 20).until { driver.current_url != private_url }
            final = driver.current_url

          else # It's a Basecamp URL, use with_driver for synchronized access
            final_url_from_bc = nil
            Utils::BasecampSession.with_driver do |bc_driver|
              return nil unless bc_driver # Should not happen if with_driver is correct

              bc_driver.navigate.to(private_url)
              # Wait up to 20s for a redirect
              Selenium::WebDriver::Wait.new(timeout: 20).until { bc_driver.current_url != private_url }
              final_url_from_bc = bc_driver.current_url
            end
            final = final_url_from_bc
          end




          if final && final =~ URI::DEFAULT_PARSER.make_regexp
            if is_google_url || !basecamp_asset_url?(final)
              log "✅ [try_browser_resolve] Redirect → #{final} (#{context})"
              return final
            end
          end
        rescue => e
          warn "⚠️ [try_browser_resolve] Failed: #{e.class}: #{e.message} (#{context})"
        end
        nil
      end

      # ------------------------------------------------------------------
      # Helper predicates & util methods
      # ------------------------------------------------------------------
      def self.extract_original_url_from_basecamp_proxy(basecamp_url)
        uri = URI(basecamp_url)
        return unless uri.query
        params = URI.decode_www_form(uri.query).to_h
        orig   = params['u'] || params['url']
        orig if orig&.match?(URI.regexp(%w[http https]))
      rescue URI::InvalidURIError
        nil
      end

      def self.embeddable_media_url?(url)
        url.match?(/(giphy|youtube|vimeo|instagram|twitter|loom|figma|miro)\.com/i)
      end

      def self.basecamp_asset_url?(url)
        url.match?(/\b(preview\.3\.basecamp\.com|storage\.3\.basecamp\.com)\b/)
      end

      def self.basecamp_cdn_url?(url)
        url.match?(/(basecamp-static\.com|bc3-production-assets-cdn\.basecamp-static\.com)/)
      end
    end
  end
end
