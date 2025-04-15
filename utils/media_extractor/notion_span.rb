# utils/media_extractor/notion_span.rb

module Utils
  module MediaExtractor
    class NotionSpan
      attr_accessor :content
      attr_reader :annotations, :link

      def initialize(text:, annotations: {}, link: nil)
        @content     = text.to_s
        @annotations = (annotations || {}).dup
        @link        = link
      end

      # Merge consecutive spans with identical formatting
      def merge_if_compatible!(other)
        return false unless same_format?(other)
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

      def to_notion_rich_text
        {
          type: 'text',
          text: {
            content: content,
            link: link ? { url: link } : nil
          }.compact,
          annotations: annotations.empty? ? {} : annotations
        }
      end
    end
  end
end
