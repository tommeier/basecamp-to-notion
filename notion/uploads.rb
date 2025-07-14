# notion/uploads.rb
#
# Helper to upload files to Notion via its official API.
# This allows Basecamp assets to be hosted on Notion's own S3 bucket
# so they remain permanently accessible.
#
# ⚠️ This relies on the `NOTION_API_TOKEN` environment variable.
#    If the env var is missing, the helper is disabled and will return nil.
#
# The upload flow using the official API typically involves:
#   1. POST /v1/file_uploads (or similar) to get a signed S3 URL and a public URL.
#   2. HTTP PUT the file bytes to the signed S3 URL.
#   3. Use the public URL in Notion blocks (e.g., image, file).
#
# If any step fails the helper logs a warning and returns nil so that callers
# can gracefully fall back to the existing Basecamp asset call-out blocks.

require 'net/http'
require 'uri'
require 'json'
require 'tempfile'
require 'marcel'
require_relative '../utils/media_extractor/uploader'
require 'open-uri'
# Removed: require_relative './auth' - Official API uses NOTION_API_TOKEN
require_relative '../utils/logging'
require_relative '../utils/http'
require_relative '../utils/media_extractor/helpers'
require_relative '../utils/media_extractor/resolver'
# require_relative '../utils/google_session' # Keep if google.rb still needs it for fetching
require 'digest/sha1'
require 'digest/md5'
require 'securerandom'
require 'timeout'
require 'base64'
require 'fileutils'
require 'mini_magick'

module Notion
  module Uploads # Renamed from PrivateUpload
    extend ::Utils::Logging

    NOTION_API_VERSION = '2022-06-28'.freeze
    NOTION_ORIGIN = ENV.fetch('NOTION_API_BASE_URL', 'https://api.notion.com').freeze # Official API Base

    # Default browser-like user agent to improve compatibility when downloading assets *before* upload
    DEFAULT_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                         'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15'.freeze


    # Timeouts (seconds) for downloading remote resources. Can be tuned via ENV at runtime.
    OPEN_TIMEOUT  = (ENV.fetch('UPLOAD_OPEN_TIMEOUT', 15)).to_i  # TCP connection setup
    READ_TIMEOUT  = (ENV.fetch('UPLOAD_READ_TIMEOUT', 60)).to_i # Full body read
    READ_TIMEOUT_LARGE = (ENV.fetch('UPLOAD_READ_TIMEOUT_LARGE', 120)).to_i
    ATTEMPT_TIMEOUT = (ENV.fetch('UPLOAD_ATTEMPT_TIMEOUT', READ_TIMEOUT * 2)).to_i
    PROGRESS_LOG_INTERVAL = (ENV.fetch('UPLOAD_PROGRESS_LOG_INTERVAL', 10)).to_i

    @api_token_checked = false # Renamed from @notion_token_checked

    def self.api_token
      ENV['NOTION_API_KEY'] # Standardized to use NOTION_API_KEY from .env
    end

    def self.enabled?
      # Check for the official NOTION_API_KEY
      token_present = !api_token.nil? && !api_token.empty?
      unless @api_token_checked
        if token_present
          log "✅ [Uploads] Notion API key (NOTION_API_KEY) is available. Uploads enabled."
        else
          warn "⚠️  [Uploads] Disabled — NOTION_API_KEY environment variable not set."
        end
        @api_token_checked = true
      end
      token_present
    end

    # Load modularized components
    # Removed: require_relative 'private_upload/session'
    # Logic for file_upload (e.g., upload_from_basecamp_url) will be defined or required separately.
    require_relative 'api'       # For low-level Notion API calls for uploads
    require_relative 'helpers'    # Restore this as notion/helpers.rb exists

    # Module to handle the orchestration of file uploads to Notion
    module FileUpload
      extend ::Utils::Logging # For log, error, warn, debug methods

      # Constants for upload sizes are now referenced from Notion::API
      # Notion::API::SINGLE_PART_MAX_SIZE_BYTES
      # Notion::API::MULTI_PART_CHUNK_SIZE_BYTES

      # https://developers.notion.com/docs/working-with-files-and-media#supported-file-types
      SUPPORTED_MIME_TYPES = [
        # Audio
        'audio/aac',
        'audio/midi', 'audio/x-midi',
        'audio/mpeg',
        'audio/ogg',
        'audio/wav', 'audio/x-wav',
        'audio/x-ms-wma',
        'audio/mp4', # For m4a, m4b

        # Document
        'application/json',
        'application/pdf',
        'text/plain',

        # Image
        'image/gif',
        'image/heic',
        'image/vnd.microsoft.icon', 'image/x-icon',
        'image/jpeg',
        'image/png',
        'image/svg+xml',
        'image/tiff',
        'image/webp',

        # Video
        'video/x-amv',
        'video/x-ms-asf',
        'video/x-msvideo',
        'video/x-f4v',
        'video/x-flv',
        'video/mp4',
        'video/mpeg',
        'video/quicktime',
        'video/x-ms-wmv',
        'video/webm'
      ].freeze

      # Helper method to convert an AVIF image to PNG
      # Returns [new_file_io, new_mime_type, temp_png_file_to_cleanup]
      # If conversion fails or is not needed, returns original_io, original_mime, nil
      def self.convert_avif_to_png(original_io, original_filename, original_mime_type, context: nil)
        log_ctx = "[FileUpload.convert_avif_to_png] Context: #{context}"
        return [original_io, original_mime_type, nil] unless original_mime_type == 'image/avif'

        debug "#{log_ctx} Detected AVIF image ('#{original_filename}'). Attempting conversion to PNG."
        avif_input_tempfile = nil
        png_output_tempfile = nil

        begin
          # Ensure original_io is at the beginning before reading
          original_io.rewind if original_io.respond_to?(:rewind)

          # Write the original AVIF IO to a tempfile for MiniMagick
          avif_input_tempfile = Tempfile.new(['avif_input_', '.avif'], binmode: true)
          avif_input_tempfile.write(original_io.read)
          avif_input_tempfile.flush
          avif_input_tempfile.rewind

          # Rewind original_io again in case conversion fails and we need to reuse it
          original_io.rewind if original_io.respond_to?(:rewind)

          image = MiniMagick::Image.open(avif_input_tempfile.path)
          image.format 'png' do |c|
            c.quality '92' # PNG quality: first digit zlib compression (0-9), second filter type (0-5). '92' is often good.
          end
          png_output_tempfile = Tempfile.new(['converted_', '.png'], binmode: true)
          image.write(png_output_tempfile.path)
          png_output_tempfile.rewind

          debug "#{log_ctx} Successfully converted '#{original_filename}' from AVIF to PNG. New size: #{png_output_tempfile.size} bytes. Tempfile: #{png_output_tempfile.path}"
          return [png_output_tempfile, 'image/png', png_output_tempfile] # Return new IO, new MIME, and the tempfile for cleanup
        rescue StandardError => e
          error "#{log_ctx} Failed to convert AVIF image '#{original_filename}' to PNG: #{e.message}. Stacktrace: #{e.backtrace.join('\n')}. Proceeding with original AVIF."
          # If conversion fails, clean up png_output_tempfile if it was created
          if png_output_tempfile
            png_output_tempfile.close rescue nil
            png_output_tempfile.unlink rescue nil
          end
          return [original_io, original_mime_type, nil] # Return original IO, original MIME, no tempfile to cleanup by caller
        ensure
          # Clean up the temp AVIF input file
          if avif_input_tempfile
            avif_input_tempfile.close rescue nil
            avif_input_tempfile.unlink rescue nil
          end
        end
      end

      # Core method to upload an IO stream to Notion
      # file_io is expected to be an open IO object (e.g., Tempfile, File)
      # original_filename is the desired name for the file in Notion
      # mime_type is the detected MIME type of the file
      def self.upload_to_notion(file_io, original_filename, mime_type, context: nil)
        log_ctx = "[FileUpload.upload_to_notion] Context: #{context}"
        png_tempfile_to_cleanup = nil # For AVIF conversion's temp PNG file

        original_filename_str = original_filename.to_s.empty? ? "untitled_upload_#{SecureRandom.hex(4)}" : original_filename.to_s

        current_file_io = file_io
        current_mime_type = mime_type

        initial_file_size_bytes = current_file_io.respond_to?(:size) ? current_file_io.size : -1 # Use -1 or handle if size not available
        initial_file_size_str = initial_file_size_bytes == -1 ? 'N/A' : "#{initial_file_size_bytes} bytes"
        debug "#{log_ctx} Starting Upload for '#{original_filename_str}' (Initial MIME: #{current_mime_type}, Initial Size: #{initial_file_size_str})"

        # --- MIME Type Detection and AVIF Conversion ---
        current_file_io.rewind if current_file_io.respond_to?(:rewind)
        marcel_mime_type = Marcel::MimeType.for(current_file_io, name: original_filename_str)
        current_file_io.rewind if current_file_io.respond_to?(:rewind)

        debug "#{log_ctx} Initial Passed MIME: '#{current_mime_type}', Marcel detected MIME: '#{marcel_mime_type}' for '#{original_filename_str}'"
        final_mime_type = marcel_mime_type.to_s.empty? ? current_mime_type : marcel_mime_type

        if final_mime_type == 'image/avif'
          debug "#{log_ctx} AVIF image detected ('#{original_filename_str}'). Attempting conversion to PNG."
          converted_io, converted_mime, temp_png = self.convert_avif_to_png(current_file_io, original_filename_str, final_mime_type, context: "#{context}:avif_conversion")
          if temp_png
            debug "#{log_ctx} AVIF successfully converted to PNG ('#{original_filename_str}'). New MIME: #{converted_mime}, Temp PNG: #{temp_png.path}"
            current_file_io = converted_io
            final_mime_type = converted_mime
            png_tempfile_to_cleanup = temp_png
          elsif converted_mime != final_mime_type
            debug "#{log_ctx} AVIF conversion failed or was skipped for '#{original_filename_str}'. Proceeding with original MIME: #{final_mime_type}."
          else
            debug "#{log_ctx} AVIF conversion helper returned original IO for '#{original_filename_str}'. Proceeding with original MIME: #{final_mime_type}."
          end
        end
        # --- End AVIF Conversion Logic ---

        temp_chunk_files = []
        single_part_temp_io = nil
        file_upload_id = nil

        begin
          is_supported_mime = SUPPORTED_MIME_TYPES.include?(final_mime_type)
          debug "#{log_ctx} Final MIME type for upload: '#{final_mime_type}' for '#{original_filename_str}'. Supported by Notion: #{is_supported_mime}"
          unless is_supported_mime
            warn "#{log_ctx} MIME type '#{final_mime_type}' for '#{original_filename_str}' is not in Notion supported types. Skipping upload."
            return { success: false, file_upload_id: nil, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: "MIME type not supported by Notion API: #{final_mime_type}" }
          end

          unless Notion::Uploads.enabled?
            warn "#{log_ctx} Notion uploads are disabled (NOTION_API_KEY not set). Skipping for '#{original_filename_str}'."
            return { success: false, file_upload_id: nil, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: "Notion uploads are disabled (NOTION_API_KEY not set)." }
          end

          current_file_io.rewind if current_file_io.respond_to?(:rewind)
          content_length = current_file_io.size
          debug "#{log_ctx} Final content length for '#{original_filename_str}' before upload: #{content_length} bytes."
          # Reference constants from Notion::API module
          debug "#{log_ctx} Max single-part upload size (from Notion::API): #{Notion::API::SINGLE_PART_MAX_SIZE_BYTES} bytes. Multi-part chunk size (from Notion::API): #{Notion::API::MULTI_PART_CHUNK_SIZE_BYTES} bytes."

          debug "#{log_ctx} Initiating upload session with Notion API for '#{original_filename_str}'..."
          start_response = Notion::API.start_file_upload(original_filename_str, final_mime_type, content_length, context: "#{context}:start_upload")
          unless start_response[:success]
            error "#{log_ctx} Failed to start Notion file upload session for '#{original_filename_str}'. Error: #{start_response[:error]}. Details: #{start_response.inspect}"
            return { success: false, file_upload_id: nil, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: start_response[:error] }
          end

          file_upload_id = start_response[:file_upload_id]
          upload_url_for_send = start_response[:upload_url]
          is_multi_part = start_response[:is_multi_part]
          filename_for_notion = start_response[:filename_for_notion]
          number_of_parts_from_api = start_response[:number_of_parts] # Might be nil if not multi-part

          debug "#{log_ctx} Notion API initiated upload session for '#{filename_for_notion}'. FileUploadID: #{file_upload_id}. Upload URL: #{upload_url_for_send}. Is Multi-part: #{is_multi_part}. Number of parts (from API): #{number_of_parts_from_api || 'N/A'}."

          if is_multi_part
            # Reference constants from Notion::API module
            debug "#{log_ctx} Proceeding with MULTI-PART upload for '#{filename_for_notion}' (ID: #{file_upload_id}). Total parts: #{number_of_parts_from_api}. Chunk size (from Notion::API): #{Notion::API::MULTI_PART_CHUNK_SIZE_BYTES} bytes."
            all_parts_sent_successfully = true
            multi_part_error_details = nil

            (1..number_of_parts_from_api).each do |part_number|
              current_file_io.rewind if part_number == 1 && current_file_io.respond_to?(:rewind)
              # Use Notion::API::MULTI_PART_CHUNK_SIZE_BYTES for reading chunks
              chunk_data = current_file_io.read(Notion::API::MULTI_PART_CHUNK_SIZE_BYTES)
              break unless chunk_data && !chunk_data.empty?

              temp_chunk_file = Tempfile.new(["notion_upload_part_#{part_number}_of_#{number_of_parts_from_api}_", File.extname(filename_for_notion)], binmode: true)
              temp_chunk_files << temp_chunk_file
              temp_chunk_file.write(chunk_data)
              temp_chunk_file.rewind

              debug "#{log_ctx} Sending part #{part_number}/#{number_of_parts_from_api} for '#{filename_for_notion}' (chunk size: #{temp_chunk_file.size} bytes) from tempfile: #{temp_chunk_file.path}"
              send_part_response = Notion::API.send_file_data(upload_url_for_send, temp_chunk_file.path, final_mime_type, filename_for_notion, part_number: part_number, context: "#{context}:send_multi_part_#{part_number}")
              temp_chunk_file.close # Close immediately after send_file_data has read it

              unless send_part_response[:success]
                multi_part_error_details = "Failed to send part #{part_number}/#{number_of_parts_from_api} for '#{filename_for_notion}'. Error: #{send_part_response[:error]}. Details: #{send_part_response[:details]}"
                error "#{log_ctx} #{multi_part_error_details}"
                all_parts_sent_successfully = false
                break
              end
              debug "#{log_ctx} Successfully sent part #{part_number}/#{number_of_parts_from_api} for '#{filename_for_notion}'."
            end

            unless all_parts_sent_successfully
              error_msg = multi_part_error_details || "One or more parts failed during multi-part upload for '#{filename_for_notion}'."
              warn "#{log_ctx} Aborting multi-part upload for '#{filename_for_notion}' (ID: #{file_upload_id}) due to part failure."
              return { success: false, file_upload_id: file_upload_id, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: error_msg }
            end

            debug "#{log_ctx} All #{number_of_parts_from_api} parts sent successfully for '#{filename_for_notion}'. Completing multi-part upload (ID: #{file_upload_id})..."
            complete_response = Notion::API.complete_multi_part_upload(file_upload_id, context: "#{context}:complete_multi_part")

            unless complete_response[:success]
              error "#{log_ctx} Failed to complete multi-part upload for '#{filename_for_notion}' (ID: #{file_upload_id}). Error: #{complete_response[:error]}. Details: #{complete_response.inspect}"
              return { success: false, file_upload_id: file_upload_id, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: complete_response[:error] }
            end

            log "#{log_ctx} MULTI-PART upload completed successfully for '#{filename_for_notion}' (ID: #{file_upload_id}). Notion URL: #{complete_response[:notion_url]}"
            return { success: true, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: complete_response[:notion_url], mime_type: final_mime_type, error: nil }

          else # Single-part upload
            debug "#{log_ctx} Proceeding with SINGLE-PART upload for '#{filename_for_notion}' (ID: #{file_upload_id})."
            path_for_send_data = nil

            if current_file_io.respond_to?(:path) && current_file_io.path && File.exist?(current_file_io.path)
              path_for_send_data = current_file_io.path
              current_file_io.rewind if current_file_io.respond_to?(:rewind)
              debug "#{log_ctx} Using existing file path for single-part upload: #{path_for_send_data}"
            else
              debug "#{log_ctx} IO for single-part upload ('#{filename_for_notion}') is not a direct file path or path is invalid. Creating temporary file."
              single_part_temp_io = Tempfile.new(["notion_single_upload_", File.extname(filename_for_notion)], binmode: true)
              current_file_io.rewind if current_file_io.respond_to?(:rewind)
              bytes_written_to_temp = single_part_temp_io.write(current_file_io.read)
              single_part_temp_io.flush
              single_part_temp_io.rewind
              path_for_send_data = single_part_temp_io.path
              debug "#{log_ctx} Created temporary file for single-part upload: #{path_for_send_data} (wrote #{bytes_written_to_temp} bytes)."
            end

            debug "#{log_ctx} Sending single-part file data for '#{filename_for_notion}' (size: #{File.size(path_for_send_data)} bytes) from path: #{path_for_send_data} to URL: #{upload_url_for_send}"
            send_response = Notion::API.send_file_data(upload_url_for_send, path_for_send_data, final_mime_type, filename_for_notion, context: "#{context}:send_single_part")

            unless send_response[:success]
              error "#{log_ctx} Failed to send single-part file data for '#{filename_for_notion}' (ID: #{file_upload_id}). Error: #{send_response[:error]}. Details: #{send_response.inspect}"
              return { success: false, file_upload_id: file_upload_id, filename: original_filename_str, notion_url: nil, mime_type: final_mime_type, error: send_response[:error] }
            end

            final_notion_url = start_response[:notion_url_after_upload] # This URL comes from the initial start_file_upload response for single-part
            log "#{log_ctx} SINGLE-PART upload successful for '#{filename_for_notion}' (ID: #{file_upload_id}). Notion URL: #{final_notion_url}"
            return { success: true, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: final_notion_url, mime_type: final_mime_type, error: nil }
          end
        rescue StandardError => e
          error_message = "Unhandled error during upload process for '#{original_filename_str}': #{e.class.name} - #{e.message}"
          error "#{log_ctx} #{error_message}\nBacktrace:\n#{e.backtrace.join("\n")}"
          current_filename_for_notion = defined?(filename_for_notion) && filename_for_notion ? filename_for_notion : original_filename_str
          return {
            success: false,
            file_upload_id: file_upload_id,
            filename: current_filename_for_notion,
            notion_url: nil,
            mime_type: final_mime_type, # Might be nil if error happened very early
            error: error_message
          }
        ensure
          debug "#{log_ctx} Entering ensure block for '#{original_filename_str}'. Cleaning up temporary files..."
          temp_chunk_files.each_with_index do |f, index|
            debug "#{log_ctx} Cleaning up temp chunk file #{index + 1}/#{temp_chunk_files.size}: #{f.path}" if f.respond_to?(:path)
            f.close unless f.closed?
            f.unlink if f.respond_to?(:unlink)
          end
          if single_part_temp_io
            debug "#{log_ctx} Cleaning up single-part temp IO: #{single_part_temp_io.path}" if single_part_temp_io.respond_to?(:path)
            single_part_temp_io.close unless single_part_temp_io.closed?
            single_part_temp_io.unlink if single_part_temp_io.respond_to?(:unlink)
          end
          if png_tempfile_to_cleanup
            debug "#{log_ctx} Cleaning up AVIF conversion temp PNG: #{png_tempfile_to_cleanup.path}" if png_tempfile_to_cleanup.respond_to?(:path)
            png_tempfile_to_cleanup.close unless png_tempfile_to_cleanup.closed?
            png_tempfile_to_cleanup.unlink if png_tempfile_to_cleanup.respond_to?(:unlink)
          end
          debug "#{log_ctx} Finished cleanup for '#{original_filename_str}'."
        end
      end

      # Uploads an asset from a Basecamp URL
      def self.upload_from_basecamp_url(basecamp_url, context: nil)
        debug "[FileUpload.upload_from_basecamp_url] Processing Basecamp URL: #{basecamp_url} - Context: #{context}"
        tempfile = nil
        resolved_url = ::Utils::MediaExtractor::Resolver.resolve_basecamp_url(basecamp_url, context) || basecamp_url
        tempfile, mime = ::Utils::MediaExtractor::Uploader.download_with_auth(resolved_url, "#{context}:download_bc_asset")

        unless tempfile && mime
          error "[FileUpload.upload_from_basecamp_url] Failed to download asset from #{resolved_url}. Tempfile: #{tempfile.inspect}, Mime: #{mime.inspect} - Context: #{context}"
          return nil
        end

        original_filename = File.basename(URI(basecamp_url).path)
        original_filename = "basecamp_asset" if original_filename.empty? # Fallback filename

        upload_result = upload_to_notion(tempfile, original_filename, mime, context: "#{context}:upload_bc_asset")
        debug "[FileUpload.upload_from_basecamp_url] Upload result for #{original_filename}: #{upload_result.inspect} - Context: #{context}"
        upload_result
      rescue StandardError => e
        error "[FileUpload.upload_from_basecamp_url] Error: #{e.message} - Context: #{context}"
        nil
      ensure
        if tempfile && tempfile.respond_to?(:close) # Check if tempfile exists and can be closed
          tempfile.close unless tempfile.closed?
          tempfile.unlink if tempfile.respond_to?(:unlink) # Tempfiles should be unlinked
        end
      end

      # Uploads an asset from a Google URL (e.g., Google Drive, Google User Content)
      def self.upload_from_google_url(google_url, context: nil)
        debug "[FileUpload.upload_from_google_url] Processing Google URL: #{google_url} - Context: #{context}"
        tempfile = nil
        resolved_url = ::Utils::MediaExtractor::Resolver.try_browser_resolve(google_url, context)
        unless resolved_url
          error "[FileUpload.upload_from_google_url] Failed to resolve Google URL: #{google_url} - Context: #{context}"
          return nil
        end

        # Google assets often require browser-based fetching.
        driver = ::Utils::GoogleSession.driver # Use Google session for Google URLs
        unless driver
          warn "[FileUpload.upload_from_google_url] No browser driver available for Google URL, trying direct fetch: #{resolved_url} - Context: #{context}"
          mime = nil # Initialize mime before assignment
          # Fallback to a simple fetch if no browser; this might fail for many Google assets.
          begin
            open(resolved_url, 'rb') do |io|
              tempfile = Tempfile.new(['google_asset_direct', File.extname(URI(resolved_url).path)], binmode: true)
              tempfile.write(io.read)
              tempfile.rewind
              # Try to get mime from content_type header or Marcel
              mime = io.content_type || ::Marcel::MimeType.for(tempfile, name: File.basename(URI(resolved_url).path))
            end
          rescue StandardError => e
            error "[FileUpload.upload_from_google_url] Direct fetch failed for #{resolved_url}: #{e.message} - Context: #{context}"
            return nil
          end
        else
          # Use BrowserCapture for robust fetching
          tempfile, mime = ::Utils::BrowserCapture.fetch(resolved_url, driver, context: "#{context}:fetch_google_asset")
        end

        unless tempfile
          error "[FileUpload.upload_from_google_url] Failed to download asset from #{resolved_url}. No tempfile created. - Context: #{context}"
          return nil
        end

        # If MIME type is missing or generic, attempt to detect using Marcel
        if mime.nil? || mime.empty? || mime == 'application/octet-stream'
          detected_mime = ::Marcel::MimeType.for(tempfile, name: File.basename(URI(resolved_url).path))
          debug "[FileUpload.upload_from_google_url] MIME type inferred via Marcel: #{detected_mime} (was: #{mime.inspect}) - Context: #{context}"
          mime = detected_mime unless detected_mime.nil? || detected_mime.empty?
        end

        unless mime && !mime.empty?
          error "[FileUpload.upload_from_google_url] Could not determine MIME type for asset from #{resolved_url} - Context: #{context}"
          return nil
        end

        original_filename = File.basename(URI(google_url).path) # Prefer original URL for filename context
        original_filename = "google_asset_#{Time.now.to_i}" if original_filename.empty? || original_filename == '/' # Fallback filename
        original_filename += File.extname(URI(resolved_url).path) if File.extname(original_filename).empty? && !File.extname(URI(resolved_url).path).empty?

        upload_result = upload_to_notion(tempfile, original_filename, mime, context: "#{context}:upload_google_asset")
        debug "[FileUpload.upload_from_google_url] Upload result for #{original_filename}: #{upload_result.inspect} - Context: #{context}"
        upload_result
      rescue StandardError => e
        error "[FileUpload.upload_from_google_url] Error: #{e.message} - Context: #{context}"
        nil
      ensure
        if tempfile && tempfile.respond_to?(:close) # Check if tempfile exists and can be closed
          tempfile.close unless tempfile.closed?
          tempfile.unlink if tempfile.respond_to?(:unlink) # Tempfiles should be unlinked
        end
      end
    end # module FileUpload
  end # module Uploads
end
