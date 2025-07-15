require 'net/http'
require 'json'
require 'uri'
require 'fileutils'
require_relative './logging'
require_relative './retry_utils'

module Utils
  module HTTP
    extend ::Utils::Logging

    # Custom Error Classes
    class HTTPError < StandardError
      attr_reader :code, :response_body
      def initialize(message, code = nil, response_body = nil)
        super(message)
        @code = code
        @response_body = response_body
      end
    end

    class RateLimitError < HTTPError
      attr_reader :retry_after
      def initialize(message = "Rate limited", code = 429, retry_after_seconds = nil, response_body = nil)
        super(message, code, response_body)
        @retry_after = retry_after_seconds
      end
    end

    class RetriableServerError < HTTPError; end # For 5xx errors
    class NonRetriableClientError < HTTPError; end # For 4xx errors (excluding 429)
    class NetworkError < StandardError; end # For transient network issues
    class ConflictError < HTTPError; end

    # Configuration for retries
    DEFAULT_MAX_RETRY_ATTEMPTS = ENV.fetch('HTTP_MAX_RETRY_ATTEMPTS', 5).to_i
    DEFAULT_INITIAL_BACKOFF_SECONDS = ENV.fetch('HTTP_INITIAL_BACKOFF_SECONDS', 1.0).to_f
    DEFAULT_MAX_BACKOFF_SECONDS = ENV.fetch('HTTP_MAX_BACKOFF_SECONDS', 30.0).to_f

    RETRIABLE_SERVER_ERROR_CODES = [500, 502, 503, 504].freeze
    # Net::ProtocolError can also be transient, e.g. for bad GZIP encoding from server
    TRANSIENT_NETWORK_ERROR_CLASSES = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Errno::ECONNREFUSED,
      Errno::EPIPE,
      Errno::ECONNABORTED,
      Net::ProtocolError,
      OpenSSL::SSL::SSLError # Can occur for transient network/SSL handshake issues
    ].freeze

    # ------------------------------------------------------------------
    # Toggle whether to persist HTTP request/response payloads to disk.
    # ------------------------------------------------------------------
    DUMP_HTTP_PAYLOADS = (ENV['DEBUG'] == 'true' || ENV['LOG_LEVEL'] == 'debug')

    def self.dump_http_payloads?
      DUMP_HTTP_PAYLOADS
    end

    @@payload_counter = 0

    DEFAULT_429_RETRY_AFTER_SECONDS = ENV.fetch('DEFAULT_429_RETRY_AFTER_SECONDS', 5).to_i

    def self.default_headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/json",
        "User-Agent" => "BasecampToNotionScript"
      }
    end

    def self.post_json(uri, payload, headers = default_headers, context: nil)
      with_retries(context: context) { request_json(:post, uri, payload, headers, context: context) }
    end

    def self.patch_json(uri, payload, headers = default_headers, context: nil)
      with_retries(context: context) { request_json(:patch, uri, payload, headers, context: context) }
    end

    def self.get_json(uri, headers = default_headers, context: nil)
      with_retries(context: context) { request_json(:get, uri, nil, headers, context: context) }
    end

    # form_data_params should be an array of parts, where each part is typically:
    # [name_string, value_string] or
    # [name_string, file_io_object, { filename: '...', content_type: '...' }]
    def self.post_multipart_form_data(uri, form_data_params, headers = default_headers, context: nil)
      uri = URI(uri.to_s) unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP) # Allow HTTP for local testing if ever needed
      raise ArgumentError, "🚫 URI is not HTTPS for production: #{uri.inspect}" if uri.is_a?(URI::HTTP) && ENV['APP_ENV'] == 'production'
      raise ArgumentError, "🚫 URI scheme is not HTTP/HTTPS: #{uri.inspect}" unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)

      with_retries(context: context) do
        raise Interrupt, "Shutdown during HTTP request" if $shutdown

        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        context_slug = (context || 'no_context').downcase.gsub(/\s+/, '_').gsub(/[^\w\-]/, '')
        @@payload_counter += 1
        file_dir = "./tmp/http_payloads"
        FileUtils.mkdir_p(file_dir) if dump_http_payloads?
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
        if dump_http_payloads?
          File.write(
            request_params_log_filename,
          "URI: #{uri}\nContext: #{context}\nHeaders (excluding Authorization): #{headers.reject { |k, _| k.downcase == 'authorization' }.inspect}\nForm Data Parts:\n#{JSON.pretty_generate(logged_form_data_info)}"
        )
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        # http.set_debug_output($stderr) # Uncomment for deep debugging

        req = Net::HTTP::Post.new(uri)

        headers.each do |k, v|
          # Content-Type for multipart/form-data is set by set_form, so don't override from general headers.
          req[k.to_s] = v.to_s unless k.downcase == 'content-type'
        end

        # Pass the form_data_params array directly.
        # Net::HTTP::Post::Multipart will create the boundary and format parts.
        req.set_form form_data_params, 'multipart/form-data'

        start_time = Time.now
        res = nil
        begin
          res = http.request(req)
        rescue *TRANSIENT_NETWORK_ERROR_CLASSES => e
          error "#{log_prefix} Network error during MULTIPART POST to #{uri}#{context ? " (#{context})" : ""}: #{e.class} - #{e.message}"
          raise NetworkError, "Network error during MULTIPART POST to #{uri}: #{e.class} - #{e.message}"
        end
        elapsed = Time.now - start_time

        body = res.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        response_filename = "#{base_filename}_response.json"
        debug "#{log_prefix} Response status: #{res.code} (#{elapsed.round(2)}s)"
        debug "#{log_prefix} Saving response payload to: #{response_filename}"
        File.write(response_filename, body) if dump_http_payloads?

        if res.code.to_i == 429 # Too Many Requests
          retry_after = (res['Retry-After'] || DEFAULT_429_RETRY_AFTER_SECONDS).to_i
          raise RateLimitError.new("Multipart POST rate limited", res.code.to_i, retry_after, body)
        end

        unless res.code.to_i.between?(200, 299)
          error "❌ HTTP MULTIPART POST failed#{context ? " (#{context})" : ""}:"
          error "URL: #{uri}"
          error "Status: #{res.code}"
          error "Request params log: #{request_params_log_filename}"
          error "Response payload: #{response_filename}"
          error "Response Body (first 500 chars): #{body.to_s[0,500]}"
          status_code = res.code.to_i
          if status_code == 429
            retry_after = (res['Retry-After'] || DEFAULT_429_RETRY_AFTER_SECONDS).to_i
            raise RateLimitError.new("Multipart POST rate limited", status_code, retry_after, body)
          elsif RETRIABLE_SERVER_ERROR_CODES.include?(status_code)
            raise RetriableServerError.new("Multipart POST server error", status_code, body)
          else
            raise NonRetriableClientError.new("Multipart POST client error or other non-retriable issue", status_code, body)
          end
        end

        begin
          # If body is empty but status is 2xx, it might be a valid success (e.g. 204 No Content)
          # However, Notion's Send File Upload API returns JSON on success.
          return { success: true, data: nil, code: res.code.to_i } if body.strip.empty? && res.code.to_i.between?(200,299)
          JSON.parse(body)
        rescue JSON::ParserError => e
          error "❌ Failed to parse JSON response for MULTIPART POST to #{uri} (Status: #{res.code}): #{e.message}"
          error "Response Body was (first 500 chars):\n#{body.to_s[0,500]}"
          # If it's a 2xx but not JSON, it's unexpected for this specific Notion endpoint.
          # We might want to return the raw body or a custom error hash.
          raise "Failed to parse JSON response (Status: #{res.code}): #{e.message}. Body snippet: #{body[0,500]}"
        end
      end
    end

    def self.request_json(method, uri, payload, headers, context: nil)
      uri = URI(uri.to_s) unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP) # Allow HTTP for local testing if ever needed
      raise ArgumentError, "🚫 URI is not HTTPS for production: #{uri.inspect}" if uri.is_a?(URI::HTTP) && ENV['APP_ENV'] == 'production'
      raise ArgumentError, "🚫 URI scheme is not HTTP/HTTPS: #{uri.inspect}" unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)

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
        FileUtils.mkdir_p(file_dir) if dump_http_payloads?
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
          File.write(request_filename, payload_json) if dump_http_payloads?
        else
          debug "#{log_prefix} Preparing request to #{uri}#{context ? " (#{context})" : ""} (No payload)"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        req = case method
              when :post then Net::HTTP::Post.new(uri)
              when :patch then Net::HTTP::Patch.new(uri)
              when :get then Net::HTTP::Get.new(uri)
              else raise ArgumentError, "Unsupported method: #{method}"
              end

        headers.each { |k, v| req[k] = v }
        req.body = JSON.generate(payload) if payload

        start_time = Time.now
        res = nil
        begin
          res = http.request(req)
        rescue *TRANSIENT_NETWORK_ERROR_CLASSES => e
          error "#{log_prefix} Network error during #{method.to_s.upcase} to #{uri}#{context ? " (#{context})" : ""}: #{e.class} - #{e.message}"
          raise NetworkError, "Network error during #{method.to_s.upcase} to #{uri}: #{e.class} - #{e.message}"
        end
        elapsed = Time.now - start_time

        body = res.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
        debug "#{log_prefix} Response status: #{res.code} (#{elapsed.round(2)}s)"
        debug "#{log_prefix} Saving response payload to: #{response_filename}"
        File.write(response_filename, body) if dump_http_payloads?

        status_code = res.code.to_i
        if status_code == 429
          retry_after = (res['Retry-After'] || DEFAULT_429_RETRY_AFTER_SECONDS).to_i
          raise RateLimitError.new("Rate limited by API", status_code, retry_after, body)
        end

        unless res.code.to_i.between?(200, 299)
          error "❌ HTTP #{method.to_s.upcase} failed#{context ? " (#{context})" : ""}:"
          error "URL: #{uri}"
          error "Status: #{res.code}"
          error "Request payload: #{request_filename}"
          error "Response payload: #{response_filename}"
          error "Response Body:\n#{body}"
          if status_code == 409
            raise ConflictError.new("HTTP #{method.to_s.upcase} failed with conflict", status_code, body)
          elsif RETRIABLE_SERVER_ERROR_CODES.include?(status_code)
            raise RetriableServerError.new("HTTP #{method.to_s.upcase} failed with server error", status_code, body)
          else # Includes other 4xx errors (that are not 409), 3xx, etc.
            raise NonRetriableClientError.new("HTTP #{method.to_s.upcase} failed with client or other non-retriable error", status_code, body)
          end
        end

        JSON.parse(body)
      end
    end

    def self.with_retries(max_attempts: DEFAULT_MAX_RETRY_ATTEMPTS, initial_backoff: DEFAULT_INITIAL_BACKOFF_SECONDS, context: nil, &block)
      log "WITH_RETRIES_ENTRY: context.inspect = #{context.inspect}, context.class = #{context.class}, context.nil? = #{context.nil?}, context.empty? = #{context.respond_to?(:empty?) ? context.empty? : 'N/A'}" # Cascade Debug
      debug "ENTERING with_retries. Initial context: #{context.inspect}"
      attempt = 0
      current_backoff_seconds = initial_backoff
      begin
        raise Interrupt, "Shutdown requested before attempt #{attempt + 1} for context: #{context}" if $shutdown
        return yield
      rescue Interrupt => e
        error "🛑 Interrupt detected during HTTP request for context: #{context}. Error: #{e.message}"
        raise e # Re-raise Interrupt to stop the process
      rescue RateLimitError => e
        attempt += 1
        log_ctx = "[HTTP Retry] Context: #{context}, Attempt: #{attempt}/#{max_attempts}"
        if attempt >= max_attempts || $shutdown
          error "#{log_ctx} Max retries reached or shutdown requested after RateLimitError. Error: #{e.message} (Code: #{e.code}). Not retrying."
          raise e # Re-raise the original RateLimitError
        end
        base_sleep_seconds = e.retry_after || DEFAULT_429_RETRY_AFTER_SECONDS # Fallback if retry_after is nil
        actual_sleep_seconds = Utils::RetryUtils.calculate_jittered_sleep(base_sleep_seconds.to_f)
        warn "#{log_ctx} ⏳ Rate limited (Code: #{e.code}). Waiting #{actual_sleep_seconds.round(2)}s (Retry-After: #{e.retry_after || 'not set'}, Base: #{base_sleep_seconds}s) before retrying. Error: #{e.message}"
        sleep(actual_sleep_seconds)
        retry
      rescue RetriableServerError, NetworkError, ConflictError => e
        log "WITH_RETRIES_RESCUE_CONTEXT_CHECK: context.inspect = #{context.inspect}, context.class = #{context.class}, context.nil? = #{context.nil?}, context.empty? = #{context.respond_to?(:empty?) ? context.empty? : 'N/A'}" # Cascade Debug
        debug "ENTERING with_retries RESCUE for #{e.class}. Context in rescue: #{context.inspect}"
        attempt += 1
        log_ctx = "[HTTP Retry] Context: #{context}, Attempt: #{attempt}/#{max_attempts}"
        if attempt >= max_attempts || $shutdown
          error_type = e.class # Simpler way to get error type string
          error "#{log_ctx} Max retries reached or shutdown requested after #{error_type} (Code: #{e.respond_to?(:code) ? e.code : 'N/A'}). Error: #{e.message}. Not retrying."
          raise e # Re-raise the original error
        end
        actual_sleep_seconds = Utils::RetryUtils.calculate_jittered_sleep(current_backoff_seconds)
        error_type_message = case e
                             when RetriableServerError
                               "Server error (Code: #{e.code})"
                             when NetworkError
                               "Network error"
                             when ConflictError
                               "Conflict error (Code: #{e.code})"
                             else
                               "Retriable error"
                             end
        warn "#{log_ctx} 🔁 #{error_type_message}. Waiting #{actual_sleep_seconds.round(2)}s (Base: #{current_backoff_seconds.round(2)}s) before retrying. Error: #{e.class} - #{e.message}"
        sleep(actual_sleep_seconds)
        current_backoff_seconds = [current_backoff_seconds * 2, DEFAULT_MAX_BACKOFF_SECONDS].min # Exponential backoff with cap
        retry
      rescue NonRetriableClientError => e
        # Log and re-raise non-retriable client errors immediately
        error "[HTTP Error] Context: #{context}. Non-retriable client error (Code: #{e.code}): #{e.message}. Body: #{e.response_body.to_s[0, 500]}"
        raise e
      rescue StandardError => e # Catch any other unexpected errors, log, and re-raise
        error "[HTTP Error] Context: #{context}. Unexpected error during HTTP request: #{e.class} - #{e.message}. Backtrace: #{e.backtrace.take(5).join('\n')}"
        raise e # Re-raise other StandardErrors without retry
      end
    end
  end
end
