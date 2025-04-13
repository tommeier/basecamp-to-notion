# utils/http.rb

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require_relative './logging'

module Utils
  module HTTP
    extend ::Utils::Logging

    @@payload_counter = 0

    def self.default_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "User-Agent" => "BasecampToNotionScript"
      }
    end

    def self.post_json(uri, payload, headers = default_headers, context: nil)
      request_json(:post, uri, payload, headers, context: context)
    end

    def self.patch_json(uri, payload, headers = default_headers, context: nil)
      request_json(:patch, uri, payload, headers, context: context)
    end

    def self.get_json(uri, headers = default_headers, context: nil)
      request_json(:get, uri, nil, headers, context: context)
    end

    def self.request_json(method, uri, payload, headers, context: nil)
      uri = URI(uri.to_s) unless uri.is_a?(URI::HTTPS)
      raise "🚫 URI is not HTTPS: #{uri.inspect}" unless uri.is_a?(URI::HTTPS)

      # 🚨 Hard protection for Notion block append misuse
      if method == :post && uri.path.include?("/blocks/") && uri.path.include?("/children")
        raise "🚫 [HTTP] Illegal POST detected for /blocks/*/children — should be PATCH! Context: #{context}, Caller: #{caller.first}"
      end


      attempt = 0
      with_retries do
        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        context_slug = (context || 'no_context').downcase.gsub(/\s+/, '_').gsub(/[^\w\-]/, '')
        @@payload_counter += 1
        file_dir = "./tmp/http_payloads"
        FileUtils.mkdir_p(file_dir)
        base_filename = "#{file_dir}/#{@@payload_counter.to_s.rjust(4, '0')}_#{method}_#{context_slug}_#{timestamp}"

        request_filename = "#{base_filename}_request.json"
        response_filename = "#{base_filename}_response.json"

        log_prefix = "📤 [HTTP #{method.to_s.upcase}]"

        # Log caller (who triggered this HTTP request)
        caller_location = caller.first
        debug "#{log_prefix} Caller: #{caller_location}"

        if payload
          payload_json = JSON.pretty_generate(payload)
          payload_size = payload_json.bytesize
          block_count = payload['children']&.size rescue nil
          debug "#{log_prefix} Preparing request to #{uri}#{context ? " (#{context})" : ""}"
          debug "#{log_prefix} Payload size: #{payload_size} bytes#{block_count ? ", blocks: #{block_count}" : ""}"
          if payload_size > 900_000
            warn "⚠️ [HTTP] Payload size exceeds 900 KB: #{payload_size} bytes — context: #{context}"
          end
          File.write(request_filename, payload_json)
        else
          debug "#{log_prefix} Preparing request to #{uri}#{context ? " (#{context})" : ""} (No payload)"
        end

        if method == :post && uri.path.match?(/\/blocks\/[^\/]+\/children/)
          error "🚨 [HTTP] POST method used for block children endpoint — Notion API expects PATCH. URI: #{uri}"
          raise "Invalid POST to /blocks/:id/children — should be PATCH!"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        req = case method
              when :post then Net::HTTP::Post.new(uri)
              when :patch then Net::HTTP::Patch.new(uri)
              when :get then Net::HTTP::Get.new(uri)
              else raise "Unsupported method: #{method}"
              end

        headers.each { |k, v| req[k] = v }
        req.body = JSON.generate(payload) if payload

        start_time = Time.now
        res = http.request(req)
        elapsed = Time.now - start_time

        body = res.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
        debug "#{log_prefix} Response status: #{res.code} (#{elapsed.round(2)}s)"
        debug "#{log_prefix} Saving response payload to: #{response_filename}"
        File.write(response_filename, body)

        if res.code.to_i == 429
          wait = (res['Retry-After'] || 5).to_i
          jitter = rand(1..3)
          total_wait = wait + jitter
          error "⏳ Rate limited. Waiting #{total_wait}s (Retry-After: #{wait}s + Jitter: #{jitter}s)..."
          sleep total_wait
          raise "Retrying after rate limit"
        end

        unless res.code.to_i.between?(200, 299)
          error "❌ HTTP #{method.to_s.upcase} failed#{context ? " (#{context})" : ""}:"
          error "URL: #{uri}"
          error "Status: #{res.code}"
          error "Request payload: #{request_filename}"
          error "Response payload: #{response_filename}"
          error "Response Body:\n#{body}"
          raise "❌ HTTP #{method.to_s.upcase} failed#{context ? " (#{context})" : ""}:\nURL: #{uri}\nStatus: #{res.code}\nBody:\n#{body}"
        end

        JSON.parse(body)
      rescue => e
        attempt += 1
        raise if attempt >= 5

        sleep_time = (2 ** attempt) + rand(1..3)
        error "🔁 Retry ##{attempt} in #{sleep_time}s due to: #{e.message}"
        sleep sleep_time
        retry
      end
    end

    def self.with_retries(max_attempts = 5)
      attempt = 0
      begin
        yield
      rescue => e
        attempt += 1
        if attempt < max_attempts
          sleep_time = (2 ** attempt) + rand(1..3)
          error "🔁 Retry ##{attempt} in #{sleep_time}s due to: #{e.message}"
          sleep sleep_time
          retry
        else
          raise e
        end
      end
    end
  end
end
