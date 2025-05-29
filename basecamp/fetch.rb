# basecamp/fetch.rb
#
# Central helpers for talking to the Basecamp API and
# downloading private assets (attachments, images) with auth.
#
require 'net/http'
require 'open-uri'
require 'uri'
require 'json'
require 'time'
require 'fileutils'

require_relative '../utils/logging'
require_relative './utils'
require_relative './auth'                    # for Basecamp::Auth.token
require_relative '../utils/media_extractor'  # to grab headers already built

module Basecamp
  module Fetch
    extend ::Utils::Logging

    PAYLOAD_LOG_DIR = "./tmp/basecamp_payloads".freeze

    # ------------------------------------------------------------
    # Public: fetch JSON (auto‑paginates, logs full payloads)
    # ------------------------------------------------------------
    def self.load_json(uri, headers = {})
      debug("🌐 GET #{uri}")
      all_data = []

      loop do
        res = Utils.with_retries { http_get(uri, headers) }

        if res.code.to_i == 429
          wait = (res['Retry-After'] || 5).to_i
          error("⏳ Rate limited. Waiting #{wait}s before retrying...")
          sleep wait
          next
        end

        if res.code == "404"
          warn("🔍 Not found (404): #{uri}")
          return []
        end

        unless res.code.to_i.between?(200, 299)
          raise "GET failed:\nURL: #{uri}\nStatus: #{res.code}\nBody:\n#{res.body}"
        end

        body = res.body
        if body.nil? || body.strip.empty?
          warn("⚠️ Empty response body for URL: #{uri}")
          return []
        end

        page_data = JSON.parse(body)

        # ✅ LOG raw API payload for debugging
        pretty = JSON.pretty_generate(page_data)
        debug("📦 Full raw API payload for #{uri}:\n#{pretty}")
        write_debug_file(uri, pretty)

        debug("🔎 Response: #{res.code}, items: #{page_data.is_a?(Array) ? page_data.size : 1}")

        return page_data unless page_data.is_a?(Array)
        all_data += page_data

        link = res['Link']
        break unless link&.include?('rel="next"')

        next_url = link.match(/<([^>]+)>;\s*rel="next"/)&.captures&.first
        break unless next_url
        uri = URI(next_url)
      end

      all_data
    end

    # ------------------------------------------------------------
    # Public: download a private asset with authentication
    # ------------------------------------------------------------
    #
    #   io = Basecamp::Fetch.download_with_auth(asset_url)
    #   # io responds to #read and #content_type
    #
    def self.download_with_auth(asset_url)
      headers = build_auth_headers
      raise "⚠️  No Basecamp auth headers available" if headers.empty?

      URI.open(asset_url, 'rb', headers)
    rescue OpenURI::HTTPError => e
      warn "⚠️  Auth download failed #{e.io.status.join(' ')} — #{asset_url}"
      nil
    rescue => e
      warn "⚠️  Error downloading asset: #{e.class} #{e.message}"
      nil
    end

    # ------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------
    def self.http_get(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        req = Net::HTTP::Get.new(uri)
        headers.each { |k, v| req[k] = v }
        http.request(req)
      end
    end

    def self.write_debug_file(uri, json)
      FileUtils.mkdir_p(PAYLOAD_LOG_DIR)
      safe = uri.to_s.gsub(%r{[^0-9A-Za-z.\-]}, "_")
      path = File.join(PAYLOAD_LOG_DIR, "basecamp_api_payload_#{safe}.json")
      File.write(path, json)
      log "📝 Basecamp API payload written to: #{path}"
    end

    # Build the same auth headers used elsewhere in the sync
    def self.build_auth_headers
      # 1️⃣ preferred: headers already set by Notion::Sync (bearer token)
      hdrs = Utils::MediaExtractor.basecamp_headers rescue nil
      return hdrs.dup if hdrs && hdrs['Authorization']

      # 2️⃣ fallback: fresh bearer token via OAuth
      token = ::Basecamp::Auth.token rescue nil
      return { 'Authorization' => "Bearer #{token}" } if token

      {}
    end

    # ────────────────────────────────────────────────────────────
    # Download using cookies from the logged‑in Basecamp browser
    # ────────────────────────────────────────────────────────────
    def self.download_with_driver_cookies(asset_url, driver)
      uri = URI(asset_url)
      cookies = driver.manage.all_cookies.select { |c|
        domain = c[:domain].sub(/^\./, '')
        uri.host.end_with?(domain)
      }.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
      return nil if cookies.empty?

      URI.open(asset_url, 'rb', 'Cookie' => cookies)
    rescue OpenURI::HTTPError
      nil
    end
  end
end
