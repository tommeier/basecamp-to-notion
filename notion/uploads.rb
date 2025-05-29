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

      # Core method to upload an IO stream to Notion
      # file_io is expected to be an open IO object (e.g., Tempfile, File)
      # original_filename is the desired name for the file in Notion
      # mime_type is the detected MIME type of the file
      def self.upload_to_notion(file_io, original_filename, mime_type, context: nil)
        log_ctx = "[FileUpload.upload_to_notion] Context: #{context}"
        log "#{log_ctx} Starting Direct Upload for '#{original_filename}' (MIME: #{mime_type}, Size: #{file_io.size} bytes)"

        unless Notion::Uploads.enabled?
          warn "#{log_ctx} Notion uploads are disabled (NOTION_API_KEY not set). Skipping upload for '#{original_filename}'."
          return { success: false, file_upload_id: nil, filename: original_filename, notion_url: nil, mime_type: mime_type, error: "Notion uploads are disabled (NOTION_API_KEY not set)." }
        end

        file_io.rewind if file_io.respond_to?(:rewind)
        content_length = file_io.size

        start_response = Notion::API.start_file_upload(original_filename, mime_type, content_length, context: "#{context}:start_upload")
        unless start_response[:success]
          error_message = "Failed to start file upload for '#{original_filename}'. Error: #{start_response[:error]}. Details: #{start_response[:details]}"
          error "#{log_ctx} #{error_message}"
          return { success: false, file_upload_id: nil, filename: original_filename, notion_url: nil, mime_type: mime_type, error: error_message }
        end

        file_upload_id = start_response[:file_upload_id]
        upload_url_for_send = start_response[:upload_url]
        is_multi_part = start_response[:is_multi_part]
        filename_for_notion = start_response[:filename_for_notion]

        log "#{log_ctx} Started upload. ID: #{file_upload_id}, Multi-part: #{is_multi_part}, Filename for Notion: #{filename_for_notion}"

        temp_chunk_files = []
        temp_file_for_io = nil
        temp_file_created_for_io = false

        if is_multi_part
          log "#{log_ctx} Performing multi-part upload with #{start_response[:number_of_parts]} parts for '#{filename_for_notion}'."
          all_parts_sent_successfully = true
          multi_part_error_details = nil # Initialize error details for parts

          begin
            (1..start_response[:number_of_parts]).each do |part_number|
              chunk_size = Notion::API::MULTI_PART_CHUNK_SIZE_BYTES
              chunk_data = file_io.read(chunk_size)
              break unless chunk_data && !chunk_data.empty?

              temp_chunk_file = Tempfile.new(["notion_upload_part_#{part_number}_", File.extname(filename_for_notion)], binmode: true)
              temp_chunk_files << temp_chunk_file
              temp_chunk_file.write(chunk_data)
              temp_chunk_file.rewind
              
              log "#{log_ctx} Sending part #{part_number}/#{start_response[:number_of_parts]} for '#{filename_for_notion}' (size: #{temp_chunk_file.size} bytes) using tempfile: #{temp_chunk_file.path}"
              
              send_part_response = Notion::API.send_file_data(
                upload_url_for_send,
                temp_chunk_file.path,
                mime_type,
                filename_for_notion,
                part_number: part_number,
                context: "#{context}:send_part_#{part_number}"
              )
              
              temp_chunk_file.close # Close immediately after send_file_data has read it
              
              unless send_part_response[:success]
                multi_part_error_details = "Failed to send part #{part_number} for '#{filename_for_notion}'. Error: #{send_part_response[:error]}. Details: #{send_part_response[:details]}"
                error "#{log_ctx} #{multi_part_error_details}"
                all_parts_sent_successfully = false
                break
              end
              log "#{log_ctx} Successfully sent part #{part_number}/#{start_response[:number_of_parts]} for '#{filename_for_notion}'."
            end # end parts loop

            unless all_parts_sent_successfully
              return { success: false, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: nil, mime_type: mime_type, error: multi_part_error_details }
            end

            # Ensure all data from file_io was read (only if all_parts_sent_successfully)
            if file_io.eof? 
              log "#{log_ctx} All parts sent for '#{filename_for_notion}'. Completing multi-part upload."
              complete_response = Notion::API.complete_multi_part_upload(file_upload_id, context: "#{context}:complete_upload")
              unless complete_response[:success]
                error_message = "Failed to complete multi-part upload for '#{filename_for_notion}'. Error: #{complete_response[:error]}. Details: #{complete_response[:details]}"
                error "#{log_ctx} #{error_message}"
                return { success: false, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: nil, mime_type: mime_type, error: error_message }
              else
                final_notion_url = complete_response.dig(:notion_response, 'url') || complete_response.dig(:notion_response, 'file', 'url')
                if final_notion_url
                  log "#{log_ctx} Successfully completed multi-part upload for '#{filename_for_notion}'. Notion URL: #{final_notion_url}"
                  return { success: true, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: final_notion_url, mime_type: mime_type, error: nil }
                else
                  error_message = "Multi-part upload completed for '#{filename_for_notion}' but no Notion URL was found in the response."
                  error "#{log_ctx} #{error_message}"
                  return { success: false, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: nil, mime_type: mime_type, error: error_message }
                end
              end
            else # Not all parts sent or file_io not fully read
              error_message = "Not all parts were sent successfully or file_io not fully read for '#{filename_for_notion}'. Aborting completion."
              error "#{log_ctx} #{error_message}"
              return { success: false, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: nil, mime_type: mime_type, error: error_message }
            end
          ensure
            temp_chunk_files.each do |f|
              f.close unless f.closed?
              f.unlink # Delete the tempfile
            end
          end # end begin-ensure for multi-part
        else # Single-part upload
          log "#{log_ctx} Performing single-part upload for '#{filename_for_notion}'."
          
          file_path_for_upload = nil

          if file_io.respond_to?(:path) && file_io.path && File.exist?(file_io.path)
            file_path_for_upload = file_io.path
            log "#{log_ctx} Using existing file path for upload: #{file_path_for_upload}"
          else
            log "#{log_ctx} file_io does not have a usable path or path does not exist. Creating a temporary file."
            temp_file_for_io = Tempfile.new(["notion_single_upload_", File.extname(filename_for_notion)], binmode: true)
            temp_file_created_for_io = true
            file_io.rewind # Ensure we read from the beginning
            temp_file_for_io.write(file_io.read)
            temp_file_for_io.rewind
            file_path_for_upload = temp_file_for_io.path
            log "#{log_ctx} Created temporary file for upload: #{file_path_for_upload}"
          end

          send_response = Notion::API.send_file_data(
            upload_url_for_send,
            file_path_for_upload,
            mime_type,
            filename_for_notion,
            context: "#{context}:send_single_part"
          )

          if temp_file_created_for_io && temp_file_for_io
            temp_file_for_io.close
            temp_file_for_io.unlink
            log "#{log_ctx} Closed and unlinked temporary file: #{file_path_for_upload}"
          end

          unless send_response[:success]
            error_message = "Failed to send file data for '#{filename_for_notion}'. Error: #{send_response[:error]}. Details: #{send_response[:details]}"
            error "#{log_ctx} #{error_message}"
            return { success: false, file_upload_id: file_upload_id, filename: filename_for_notion, notion_url: nil, mime_type: mime_type, error: error_message }
          else
            log "#{log_ctx} Successfully sent file data for '#{filename_for_notion}'. Notion status: #{send_response.dig(:notion_response, 'status') || 'unknown'}."
            # For single-part uploads, the /send endpoint response does not contain a direct 'url'.
            # The file is identified by file_upload_id for attachment in a subsequent step.
            # filename_for_notion was already derived from the start_file_upload step and confirmed by Notion in send_response.
            return {
              success: true,
              file_upload_id: file_upload_id,
              filename: filename_for_notion, # filename confirmed by Notion from start_file_upload
              notion_url: nil, # Expected to be nil, as direct URL isn't provided here.
              mime_type: mime_type,
              error: nil
            }
          end
        end # end if is_multi_part / else

      rescue StandardError => e
        error_message = "Unhandled error during upload for '#{original_filename}': #{e.message}"
        error "#{log_ctx} #{error_message}\nBacktrace:\n#{e.backtrace.join("\n")}"
        # Ensure any tempfiles created in this scope are cleaned up
        temp_chunk_files.each do |f|
          f.close unless f.closed?
          f.unlink
        end
        if temp_file_created_for_io && temp_file_for_io
             temp_file_for_io.close unless temp_file_for_io.closed?
             temp_file_for_io.unlink
        end
        # Try to return consistent hash even in rescue
        current_file_upload_id = defined?(file_upload_id) ? file_upload_id : nil
        current_filename_for_notion = defined?(filename_for_notion) ? filename_for_notion : original_filename

        return {
          success: false,
          file_upload_id: current_file_upload_id,
          filename: current_filename_for_notion,
          notion_url: nil,
          mime_type: mime_type, # mime_type should always be available as it's a param
          error: error_message
        }
      # Ensure original file_io is NOT closed here, as its lifecycle is managed by the caller.
      # We only manage tempfiles created within this method.
      end

      # Uploads an asset from a Basecamp URL
      def self.upload_from_basecamp_url(basecamp_url, context: nil)
        log "[FileUpload.upload_from_basecamp_url] Processing Basecamp URL: #{basecamp_url} - Context: #{context}"
        tempfile = nil
        resolved_url = ::Utils::MediaExtractor::Resolver.resolve_basecamp_url(basecamp_url, context) || basecamp_url
        tempfile, mime = ::Utils::MediaExtractor::Uploader.download_with_auth(resolved_url, "#{context}:download_bc_asset")
        
        unless tempfile && mime
          error "[FileUpload.upload_from_basecamp_url] Failed to download asset from #{resolved_url}. - Context: #{context}"
          return nil
        end

        original_filename = File.basename(URI(basecamp_url).path)
        original_filename = "basecamp_asset" if original_filename.empty? # Fallback filename

        upload_result = upload_to_notion(tempfile, original_filename, mime, context: "#{context}:upload_bc_asset")
        upload_result
      rescue StandardError => e
        error "[FileUpload.upload_from_basecamp_url] Error: #{e.message} - Context: #{context}"
        nil
      ensure
        # tempfile should be closed by upload_to_notion -> upload_file_to_s3
        # If download_with_auth creates a tempfile that isn't passed, it should close it.
        # Assuming download_with_auth returns a Tempfile that it expects caller or downstream to manage.
        tempfile&.close if tempfile && tempfile.respond_to?(:close) && !tempfile.closed? && upload_result.nil? # Clean up if upload didn't happen
      end

      # Uploads an asset from a Google URL (e.g., Google Drive, Google User Content)
      def self.upload_from_google_url(google_url, context: nil)
        log "[FileUpload.upload_from_google_url] Processing Google URL: #{google_url} - Context: #{context}"
        tempfile = nil
        resolved_url = ::Utils::MediaExtractor::Resolver.try_browser_resolve(google_url, context)
        unless resolved_url
          error "[FileUpload.upload_from_google_url] Failed to resolve Google URL: #{google_url} - Context: #{context}"
          return nil
        end

        # Google assets often require browser-based fetching.
        driver = ::Utils::BasecampSession.driver # Assumes a shared browser session is available
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
        
        unless tempfile && mime
          error "[FileUpload.upload_from_google_url] Failed to download asset from #{resolved_url}. - Context: #{context}"
          return nil
        end

        original_filename = File.basename(URI(google_url).path) # Prefer original URL for filename context
        original_filename = "google_asset_#{Time.now.to_i}" if original_filename.empty? || original_filename == '/' # Fallback filename
        original_filename += File.extname(URI(resolved_url).path) if File.extname(original_filename).empty? && !File.extname(URI(resolved_url).path).empty?

        upload_result = upload_to_notion(tempfile, original_filename, mime, context: "#{context}:upload_google_asset")
        upload_result
      rescue StandardError => e
        error "[FileUpload.upload_from_google_url] Error: #{e.message} - Context: #{context}"
        nil
      ensure
        # tempfile should be closed by upload_to_notion -> upload_file_to_s3
        tempfile&.close if tempfile && tempfile.respond_to?(:close) && !tempfile.closed? && upload_result.nil? # Clean up if upload didn't happen
      end
    end # module FileUpload
  end # module Uploads
end
