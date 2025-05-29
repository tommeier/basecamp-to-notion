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

    # form_data_params should be an array of parts, where each part is typically:
    # [name_string, value_string] or
    # [name_string, file_io_object, { filename: '...', content_type: '...' }]
    def self.post_multipart_form_data(uri, form_data_params, headers = default_headers, context: nil)
      uri = URI(uri.to_s) unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP) # Allow HTTP for local testing if ever needed
      raise "🚫 URI is not HTTPS for production: #{uri.inspect}" if uri.is_a?(URI::HTTP) && ENV['APP_ENV'] == 'production'
      raise "🚫 URI scheme is not HTTP/HTTPS: #{uri.inspect}" unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)

      with_retries do
        raise Interrupt, "Shutdown during HTTP request" if $shutdown

        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        context_slug = (context || 'no_context').downcase.gsub(/\s+/, '_').gsub(/[^\w\-]/, '')
        @@payload_counter += 1
        file_dir = "./tmp/http_payloads"
        FileUtils.mkdir_p(file_dir)
        base_filename = "#{file_dir}/#{@@payload_counter.to_s.rjust(4, '0')}_multipart_post_#{context_slug}_#{timestamp}"

        request_params_log_filename = "#{base_filename}_request_params.log"
        
        log_prefix = "📤 [HTTP MULTIPART POST]"
        caller_location = caller.first
        debug "#{log_prefix} Caller: #{caller_location}"

        # Log form_data_params structure (now an array of arrays/parts)
        logged_form_data_info = form_data_params.map do |part|
          key = part[0]
          value = part[1]
          opts = part[2] if part.size > 2

          value_info = if value.is_a?(File)
            "File(path: #{value.path}, size: #{value.size rescue 'unknown'})"
          elsif value.respond_to?(:path) && value.respond_to?(:read) # Duck-typing for IO-like objects
            "IO-like(path: #{value.path rescue 'unknown'}, size: #{value.size rescue 'unknown'})"
          else
            value.to_s.truncate(100) # Truncate potentially long string values
          end
          
          log_entry = "#{key}: #{value_info}"
          log_entry += " (opts: #{opts.inspect})" if opts
          log_entry
        end
        debug "#{log_prefix} Preparing request to #{uri}#{context ? " (#{context})" : ""}"
        debug "#{log_prefix} Form data parts: #{logged_form_data_info.inspect}"
        File.write(
          request_params_log_filename, 
          "URI: #{uri}\nContext: #{context}\nHeaders (excluding Authorization): #{headers.reject { |k, _| k.downcase == 'authorization' }.inspect}\nForm Data Parts:\n#{JSON.pretty_generate(logged_form_data_info)}"
        )

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        # http.set_debug_output($stderr) # Uncomment for deep debugging

        req = Net::HTTP::Post.new(uri)
        
        headers.each do |k, v|
          # Content-Type for multipart/form-data is set by set_form, so don't override from general headers.
          req[k.to_s] = v.to_s unless k.downcase == 'content-type'
        end
        
        # Pass the form_data_params array directly. 
        # Net::HTTP::Post#set_form can handle an array of [key, val] or [key, val, opts] parts.
        req.set_form(form_data_params, 'multipart/form-data')

        start_time = Time.now
        res = http.request(req)
        elapsed = Time.now - start_time

        body = res.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        response_filename = "#{base_filename}_response.json"
        debug "#{log_prefix} Response status: #{res.code} (#{elapsed.round(2)}s)"
        debug "#{log_prefix} Saving response payload to: #{response_filename}"
        File.write(response_filename, body)

        if res.code.to_i == 429 # Too Many Requests
          wait = (res['Retry-After'] || 5).to_i
          jitter = rand(1..3)
          total_wait = wait + jitter
          error "⏳ Rate limited. Waiting #{total_wait}s (Retry-After: #{wait}s + Jitter: #{jitter}s)..."
          sleep total_wait
          raise "Retrying after rate limit"
        end

        unless res.code.to_i.between?(200, 299)
          error "❌ HTTP MULTIPART POST failed#{context ? " (#{context})" : ""}:"
          error "URL: #{uri}"
          error "Status: #{res.code}"
          error "Request params log: #{request_params_log_filename}"
          error "Response payload: #{response_filename}"
          error "Response Body snippet (first 500 chars):\n#{body[0, 500]}"
          raise "❌ HTTP MULTIPART POST failed#{context ? " (#{context})" : ""}: URL: #{uri}, Status: #{res.code}, Body: #{body[0,500]}"
        end

        begin
          # If body is empty but status is 2xx, it might be a valid success (e.g. 204 No Content)
          # However, Notion's Send File Upload API returns JSON on success.
          return { success: true, data: nil, code: res.code.to_i } if body.strip.empty? && res.code.to_i.between?(200,299)
          JSON.parse(body)
        rescue JSON::ParserError => e
          error "❌ Failed to parse JSON response for MULTIPART POST to #{uri} (Status: #{res.code}): #{e.message}"
          error "Response Body was (first 500 chars):\n#{body[0,500]}"
          # If it's a 2xx but not JSON, it's unexpected for this specific Notion endpoint.
          # We might want to return the raw body or a custom error hash.
          raise "Failed to parse JSON response (Status: #{res.code}): #{e.message}. Body snippet: #{body[0,500]}"
        end
      end
    end

    def self.request_json(method, uri, payload, headers, context: nil)
      uri = URI(uri.to_s) unless uri.is_a?(URI::HTTPS)
      raise "🚫 URI is not HTTPS: #{uri.inspect}" unless uri.is_a?(URI::HTTPS)

      # 🚨 Hard protection for Notion block append misuse
      if method == :post && uri.path.include?("/blocks/") && uri.path.include?("/children")
        raise "🚫 [HTTP] Illegal POST detected for /blocks/*/children — should be PATCH! Context: #{context}, Caller: #{caller.first}"
      end

      with_retries do
        raise Interrupt, "Shutdown during HTTP request" if $shutdown

        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        context_slug = (context || 'no_context').downcase.gsub(/\s+/, '_').gsub(/[^\w\-]/, '')
        @@payload_counter += 1
        file_dir = "./tmp/http_payloads"
        FileUtils.mkdir_p(file_dir)
        base_filename = "#{file_dir}/#{@@payload_counter.to_s.rjust(4, '0')}_#{method}_#{context_slug}_#{timestamp}"

        request_filename = "#{base_filename}_request.json"
        response_filename = "#{base_filename}_response.json"

        log_prefix = "📤 [HTTP #{method.to_s.upcase}]"
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
      end
    end

    def self.with_retries(max_attempts = 5)
      attempt = 0
      begin
        raise Interrupt, "Shutdown requested before attempt #{attempt + 1}" if $shutdown

        yield
      rescue Interrupt => e
        error "🛑 Interrupt detected during HTTP request: #{e.message}"
        raise e
      rescue => e
        attempt += 1
        raise if attempt >= max_attempts || $shutdown

        sleep_time = (2 ** attempt) + rand(1..3)
        error "🔁 Retry ##{attempt} in #{sleep_time}s due to: #{e.message}"

        sleep_time.times do
          sleep 1
          raise Interrupt, "Shutdown during retry sleep" if $shutdown
        end

        retry
      end
    end
  end
end
