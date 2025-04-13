# /basecamp/fetch.rb

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'fileutils'

require_relative '../utils/logging'
require_relative './utils'

module Basecamp
  module Fetch
    extend ::Utils::Logging

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

        # ✅ LOG FULL PAYLOAD FOR DEBUGGING
        pretty_json = JSON.pretty_generate(page_data)
        debug("📦 Full raw API payload for #{uri}:\n#{pretty_json}")
        write_debug_file(uri, pretty_json)

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

    def self.http_get(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        req = Net::HTTP::Get.new(uri)
        headers.each { |k, v| req[k] = v }
        http.request(req)
      end
    end

    def self.write_debug_file(uri, json_data)
      FileUtils.mkdir_p("./tmp")
      file_safe_uri = uri.to_s.gsub(%r{[^0-9A-Za-z.\-]}, "_")
      file_path = "./tmp/basecamp_api_payload_#{file_safe_uri}.json"
      File.open(file_path, "w") { |f| f.write(json_data) }
      log "📝 Basecamp API payload written to: #{file_path}"
    end
  end
end
