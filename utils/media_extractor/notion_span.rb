# utils/media_extractor/notion_span.rb
require_relative './constants'

module Utils
  module MediaExtractor
    class NotionSpan
      attr_accessor :content, :link
      attr_reader :annotations

      def initialize(text:, annotations: {}, link: nil)
        @content     = text.to_s
        @annotations = (annotations || {}).dup
        @link        = link
      end

      # Merge consecutive spans with identical formatting
      def merge_if_compatible!(other)
        return false unless same_format?(other)
        return false if (self.content.bytesize + other.content.bytesize) > MAX_NOTION_TEXT_LENGTH
        self.content << other.content
        true
      end

      def same_format?(other)
        annotations == other.annotations && link == other.link
      end

      def debug_description
        desc = "'#{content}'"
        desc += " annotations=#{annotations}" unless annotations.empty?
        desc += " link=#{link}" if link
        desc
      end

      # Always chunks into safe ≤2000-char segments, returns array
      def to_notion_rich_text
        return [] if content.empty?

        content.scan(/.{1,#{MAX_NOTION_TEXT_LENGTH}}/m).map do |chunk|
          safe_link = nil
          if link && link.strip.length <= MAX_NOTION_TEXT_LENGTH
            begin
              uri = URI.parse(link.strip)
              if uri.host && uri.scheme&.match?(/^https?$/)
                safe_link = link.strip
              else
                Utils::Logger.warn("⚠️ Invalid or incomplete URL rejected in NotionSpan: #{link.inspect}")
              end
            rescue URI::InvalidURIError => e
              Utils::Logger.warn("⚠️ Invalid URI in NotionSpan (#{e.message}): #{link.inspect}")
            end
          end

          {
            type: 'text',
            text: {
              content: chunk,
              link: safe_link ? { url: safe_link } : nil
            }.compact,
            annotations: annotations.empty? ? {} : annotations
          }
        end
      end
    end
  end
end
