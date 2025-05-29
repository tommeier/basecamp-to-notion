# utils/media_extractor/helpers.rb

require 'net/http'
require_relative '../file_reporter'
require_relative '../logging'
require_relative './constants'
require_relative './logger'

module Utils
  module MediaExtractor
    module Helpers
      extend ::Utils::Logging

      @logged_manual_uploads = Set.new

      def self.clean_url(url)
        return nil if url.nil? || url.to_s.strip.empty?

        cleaned = url.to_s.gsub(/\s+/, '').strip
        cleaned.empty? ? nil : cleaned
      end

      def self.url_public?(url)
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)
        response.is_a?(Net::HTTPSuccess)
      rescue => e
        warn "⚠️ [url_public?] Error checking URL #{url}: #{e.message}"
        false
      end

      def self.text_segment(content, link: nil)
        content = content.to_s.strip
        cleaned_link = clean_url(link)

        return nil if content.empty? && cleaned_link.nil?

        text = { content: content }
        text[:link] = { url: cleaned_link } if cleaned_link

        { type: "text", text: text }
      end

      def self.fallback_paragraph_block(text)
        cleaned = text.to_s.strip
        {
          object: "block",
          type: "paragraph",
          paragraph: {
            rich_text: [{
              type: "text",
              text: { content: cleaned.empty? ? "(empty)" : cleaned }
            }]
          }
        }
      end

      def self.chunk_rich_text(rich_text)
        chunks = []
        current_chunk = []
        current_bytesize = 0
        max_bytes = MAX_NOTION_TEXT_LENGTH - 100

        rich_text.compact.each do |segment|
          content = segment.dig(:text, :content).to_s
          next if content.strip.empty?

          encoded = content.encode("UTF-8")

          if encoded.bytesize > max_bytes
            debug "🚨 [chunk_rich_text] Segment exceeds max byte limit (#{encoded.bytesize}) — splitting (safe)"
            temp = ""
            encoded.each_char do |char|
              char_bytes = char.bytesize
              if temp.bytesize + char_bytes > max_bytes
                chunks << [{ type: "text", text: { content: temp } }]
                temp = ""
              end
              temp << char
            end
            chunks << [{ type: "text", text: { content: temp } }] unless temp.empty?
            next
          end

          if current_bytesize + encoded.bytesize > max_bytes
            chunks << current_chunk
            debug "🧩 [chunk_rich_text] Chunk byte limit reached: #{current_bytesize} bytes, starting new chunk"
            current_chunk = []
            current_bytesize = 0
          end

          current_chunk << segment
          current_bytesize += encoded.bytesize
        end

        chunks << current_chunk unless current_chunk.empty?
        chunks
      end

      def self.build_embed_block(url, context = nil)
        cleaned_url = clean_url(url)
        unless cleaned_url
          warn "⚠️ [build_embed_block] Skipped empty embed URL (#{context})"
          return nil
        end

        {
          object: "block",
          type: "embed",
          embed: { url: cleaned_url }
        }
      end

      def self.log_manual_upload(url, notion_page_id, context)
        cleaned_url = clean_url(url)
        return unless cleaned_url

        @logged_manual_uploads ||= Set.new
        return if @logged_manual_uploads.include?(cleaned_url)

        FileReporter.add(cleaned_url, notion_page_id, context)
        log "📋 [manual_upload] Required: #{cleaned_url} (#{context})"
        @logged_manual_uploads << cleaned_url
      end

      def self.clear_local_directory
        local_dir = "./manual_uploads"
        FileUtils.rm_rf(local_dir)
        FileUtils.mkdir_p(local_dir)
        log "🧹 [clear_local_directory] Cleared: #{local_dir}"
      end

      # Returns the MIME type for a given filename, or application/octet-stream if unknown
      IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .svg .webp .heic .heif].freeze

      def self.image_url?(url)
        return false if url.nil? || url.to_s.strip.empty?
        begin
          uri = URI.parse(url.to_s)
          ext = File.extname(uri.path).downcase
          IMAGE_EXTENSIONS.include?(ext)
        rescue URI::InvalidURIError
          false # Not a valid URL
        end
      end

      def self.mime_type_for(filename)
        require 'mime/types'
        ext = File.extname(filename).downcase.sub('.', '')
        return 'application/octet-stream' if ext.empty?
        mime = MIME::Types.type_for(ext).first
        mime ? mime.content_type : 'application/octet-stream'
      end

    end
  end
end
