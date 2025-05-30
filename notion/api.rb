# /notion/api.rb
require 'net/http'
require 'json'
require 'uri'
require_relative '../config' # Defines NOTION_API_KEY
require_relative '../utils/logging'
require_relative '../utils/http'

module Notion
  module API
    extend ::Utils::Logging

    NOTION_API_BASE_URL = ENV.fetch('NOTION_API_BASE_URL', 'https://api.notion.com').freeze
    SINGLE_PART_MAX_SIZE_BYTES = 20 * 1024 * 1024 # 20 MB
    # Recommended part size by Notion is 10MB for multi-part, min 5MB, max 20MB (except last part)
    MULTI_PART_CHUNK_SIZE_BYTES = 10 * 1024 * 1024 # 10 MB

    def self.default_headers
      {
        "Authorization" => "Bearer #{NOTION_API_KEY}",
        "Notion-Version" => "2022-06-28",
        "Content-Type" => "application/json"
      }
    end

    # Headers for sending actual file data (multipart/form-data)
    # Content-Type is handled by Net::HTTP's set_form
    def self.default_api_headers_for_file_data_upload
      {
        "Authorization" => "Bearer #{NOTION_API_KEY}",
        "Notion-Version" => "2022-06-28"
        # "Content-Type" will be set by Net::HTTP for multipart/form-data
      }
    end

    def self.post_json(uri, payload, headers = default_headers, context: nil)
      ::Utils::HTTP.post_json(uri, payload, headers, context: context)
    end

    def self.patch_json(uri, payload, headers = default_headers, context: nil)
      ::Utils::HTTP.patch_json(uri, payload, headers, context: context)
    end

    def self.get_json(uri, headers = default_headers, context: nil)
      ::Utils::HTTP.request_json(:get, uri, nil, headers, context: context)
    end

    # Ensures filename has an extension based on MIME type.
    # Returns the original name if it already has an extension or if MIME type is unknown.
    def self.filename_with_extension(name, mime_type, context: nil)
      log_ctx = "[Notion::API.filename_with_extension] Context: #{context}"
      log "#{log_ctx} Received name: '#{name}', mime_type: '#{mime_type}'"

      # If name is nil or empty, generate a placeholder
      effective_name = name.nil? || name.strip.empty? ? "untitled_file_#{Time.now.to_i}" : name

      unless File.extname(effective_name).empty?
        log "#{log_ctx} Name '#{effective_name}' already has an extension. Returning as is."
        return effective_name
      end

      unless mime_type
        log "#{log_ctx} Mime_type is nil for '#{effective_name}'. Returning as is."
        return effective_name
      end

      ext = case mime_type.to_s.downcase.strip # Ensure mime_type is a string and normalized
            when 'image/jpeg', 'image/jpg' then '.jpg'
            when 'image/png' then '.png'
            when 'image/gif' then '.gif'
            when 'application/pdf' then '.pdf'
            when 'text/plain' then '.txt'
            when 'text/csv' then '.csv'
            when 'image/heic' then '.heic'
            when 'image/heif' then '.heif'
            when 'image/webp' then '.webp'
            when 'video/mp4' then '.mp4'
            when 'video/quicktime', 'video/mov' then '.mov' # Added video/mov
            when 'application/zip' then '.zip'
            when 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' then '.docx'
            when 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' then '.xlsx'
            when 'application/vnd.openxmlformats-officedocument.presentationml.presentation' then '.pptx'
            # Add more mappings as needed based on Notion's supported types
            when 'audio/aac' then '.aac'
            when 'audio/mpeg' then '.mp3' # Common for mp3
            when 'audio/ogg' then '.ogg'
            when 'audio/wav' then '.wav'
            when 'image/svg+xml' then '.svg'
            else
              log "#{log_ctx} Unknown mime_type '#{mime_type}' for '#{effective_name}'. No extension added."
              nil
            end

      if ext
        modified_name = "#{File.basename(effective_name, '.*')}#{ext}" # Ensure no double extensions if base had one somehow
        log "#{log_ctx} Determined extension '#{ext}' for mime_type '#{mime_type}'. Modified name: '#{modified_name}'"
        return modified_name
      else
        log "#{log_ctx} No extension determined for mime_type '#{mime_type}'. Returning original name '#{effective_name}'."
        return effective_name
      end
    end

    # Step 1: Create a File Upload object (initiates the upload)
    # https://developers.notion.com/docs/uploading-small-files#step-1-create-a-file-upload-object
    # https://developers.notion.com/docs/sending-larger-files#step-2-start-a-file-upload
    def self.start_file_upload(original_filename, mime_type, file_size_bytes, context: nil)
      log_ctx = "[Notion::API.start_file_upload] Context: #{context}"
      log "#{log_ctx} Initiating for: '#{original_filename}', MIME: '#{mime_type}', Size: #{file_size_bytes} bytes"

      api_url = URI("#{NOTION_API_BASE_URL}/v1/file_uploads")
      filename_for_payload = filename_with_extension(original_filename, mime_type, context: "#{context}:filename_helper_for_start")
      
      payload = {}
      is_multi_part = file_size_bytes > SINGLE_PART_MAX_SIZE_BYTES

      if is_multi_part
        number_of_parts = (file_size_bytes.to_f / MULTI_PART_CHUNK_SIZE_BYTES).ceil
        payload[:mode] = "multi_part"
        payload[:number_of_parts] = number_of_parts
        payload[:filename] = filename_for_payload # Required for multi-part start
        log "#{log_ctx} Multi-part upload detected. Parts: #{number_of_parts}, Filename for payload: #{filename_for_payload}"
      else
        # For single-part, filename is sent via x-notion-filename header in the next step,
        # but the docs for "Create a file upload object" show an empty payload {}
        # and the response includes filename: null.
        # The filename seems to be set during the actual file content POST for single-part.
        log "#{log_ctx} Single-part upload detected. Filename for reference: #{filename_for_payload}"
      end

      log "#{log_ctx} POSTing to #{api_url} with payload: #{payload.inspect}"
      response = post_json(api_url, payload, default_headers, context: "#{context}:start_upload_http")

      unless response && response['id'] && response['upload_url']
        error "#{log_ctx} Failed to start file upload. Response: #{response.inspect}"
        return { success: false, error: "Failed to start file upload", details: response }
      end

      log "#{log_ctx} Successfully started. ID: #{response['id']}, Upload URL: #{response['upload_url']}"
      {
        success: true,
        file_upload_id: response['id'],
        upload_url: response['upload_url'], # This is the URL for sending file data (e.g., .../send)
        is_multi_part: is_multi_part,
        number_of_parts: is_multi_part ? number_of_parts : 1,
        # filename_for_header will be used by the caller for the x-notion-filename header if needed for single-part
        # or can be derived again from original_filename and mime_type.
        # For multi-part, filename was already in the start_file_upload payload.
        filename_for_notion: filename_for_payload
      }
    rescue StandardError => e
      error "#{log_ctx} Error: #{e.message}\n#{e.backtrace.join("\n")}"
      { success: false, error: e.message }
    end

    # Step 2: Upload file contents (single or one part of multi-part)
    # https://developers.notion.com/docs/uploading-small-files#step-2-upload-file-contents
    # https://developers.notion.com/docs/sending-larger-files#step-3-send-all-file-parts
    # `file_path` is the path to the actual file on disk (or a part of it)
    # `filename_for_header` is the desired filename for Notion (e.g., "image.jpg")
    # `mime_type_for_header` is the MIME type of the file (e.g., "image/jpeg")
    def self.send_file_data(upload_url_from_step1, file_path, mime_type_for_header, filename_for_header, part_number: nil, context: nil)
      log_ctx = "[Notion::API.send_file_data] Context: #{context}"
      log "#{log_ctx} Sending data for: '#{file_path}', Filename: '#{filename_for_header}', MIME: '#{mime_type_for_header}', Part: #{part_number || 'N/A (single)'}"

      unless File.exist?(file_path)
        error "#{log_ctx} File not found at path: #{file_path}"
        return { success: false, error: "File not found: #{file_path}" }
      end

      file_object_to_upload = nil # Initialize to ensure it's in scope for ensure/finally block equivalent
      begin
        file_object_to_upload = File.open(file_path, 'rb')

        # Prepare form_parts for Net::HTTP::Post#set_form
        # Each part can be [name, value] or [name, value, opts_hash]
        # For files, opts_hash should be { content_type: '...', filename: '...' }
        form_parts = [
          ['file', file_object_to_upload, { content_type: mime_type_for_header, filename: filename_for_header }]
        ]
        form_parts << ['part_number', part_number.to_s] if part_number

        api_url = URI(upload_url_from_step1)
        log "#{log_ctx} POSTing multipart-form-data to #{api_url}. File: #{file_path}, Part: #{part_number || 'single'}"

        headers = default_api_headers_for_file_data_upload.dup

        response = ::Utils::HTTP.post_multipart_form_data(
          api_url,
          form_parts, # Pass the array of parts
          headers,
          context: "#{context}:send_data_http"
        )

        # `post_multipart_form_data` already parses JSON and checks for 2xx
        # A successful response to POST /send includes status: "uploaded"
        if response && response.is_a?(Hash) && response['status'] == 'uploaded'
          log "#{log_ctx} Successfully sent data for '#{file_path}'. Notion status: #{response['status']}. Filename by Notion: #{response['filename']}"
          return { success: true, notion_response: response }
        elsif response && response.is_a?(Hash) # It was a 2xx but status not 'uploaded' or other issue
          error "#{log_ctx} Sent data for '#{file_path}', but Notion status is not 'uploaded'. Response: #{response.inspect}"
          return { success: false, error: "Notion status not 'uploaded'", details: response }
        else # This case should ideally be caught by post_multipart_form_data's error handling if not 2xx
          error "#{log_ctx} Failed to send data for '#{file_path}'. Response: #{response.inspect}"
          return { success: false, error: "Failed to send file data", details: response }
        end

      rescue StandardError => e
        error "#{log_ctx} Error: #{e.message}\n#{e.backtrace.join("\n")}"
        { success: false, error: e.message }
      ensure
        # Ensure file is closed if it was opened
        if file_object_to_upload && file_object_to_upload.respond_to?(:close) && !file_object_to_upload.closed?
          file_object_to_upload.close
        end
      end
    end

    # Step 4 (for multi-part): Complete the file upload
    # https://developers.notion.com/docs/sending-larger-files#step-4-complete-the-file-upload
    def self.complete_multi_part_upload(file_upload_id, context: nil)
      log_ctx = "[Notion::API.complete_multi_part_upload] Context: #{context}"
      log "#{log_ctx} Completing multi-part upload for ID: #{file_upload_id}"

      api_url = URI("#{NOTION_API_BASE_URL}/v1/file_uploads/#{file_upload_id}/complete")
      # The payload should be an empty JSON object `{}` according to API reference for this endpoint.
      # However, the docs page for "Sending Larger Files" Step 4 example shows --data '{}' for cURL,
      # which implies Content-Type: application/json.
      payload = {} 

      log "#{log_ctx} POSTing to #{api_url} with payload: #{payload.inspect}"
      response = post_json(api_url, payload, default_headers, context: "#{context}:complete_upload_http")

      # A successful response should have status: "uploaded"
      if response && response.is_a?(Hash) && response['status'] == 'uploaded'
        log "#{log_ctx} Successfully completed multi-part upload for ID: #{file_upload_id}. Notion status: #{response['status']}"
        return { success: true, notion_response: response }
      else
        error "#{log_ctx} Failed to complete multi-part upload for ID: #{file_upload_id}. Response: #{response.inspect}"
        return { success: false, error: "Failed to complete multi-part upload", details: response }
      end
    rescue StandardError => e
      error "#{log_ctx} Error: #{e.message}\n#{e.backtrace.join("\n")}"
      { success: false, error: e.message }
    end
  end
end
