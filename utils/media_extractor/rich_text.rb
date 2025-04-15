# utils/media_extractor/rich_text.rb

require 'nokogiri'
require_relative './notion_span'
require_relative './logger'

module Utils
  module MediaExtractor
    module RichText
      extend self

      MAX_NOTION_TEXT_LENGTH = 2000

      def extract_rich_text_from_fragment(fragment, context = nil)
        return [] unless fragment

        Logger.debug("[RichText] extract start => #{fragment.to_html.inspect} (#{context})")

        spans = []
        fragment.children.each do |node|
          spans.concat process_node(node, {}, nil, context)
        end
        Logger.debug("[RichText] raw => #{spans.map(&:debug_description)} (#{context})")

        merged = merge_consecutive_spans(spans)
        trim_trailing_newlines(merged)
        chunked = chunk_spans(merged)

        Logger.debug("[RichText] final chunked => #{chunked.map(&:debug_description)} (#{context})")

        chunked.map(&:to_notion_rich_text)
      rescue => e
        Logger.error("[RichText] error: #{e.message}\n#{e.backtrace.join("\n")}")
        []
      end

      private

      def process_node(node, annotations, link, context)
        return [] if node.comment?

        if node.text?
          txt = node.text
          return [] if txt.empty?

          span = NotionSpan.new(text: txt, annotations: annotations, link: link)
          Logger.debug("[RichText] span => #{span.debug_description} (#{context})")
          [span]

        elsif node.element?
          return [newline_span(annotations, link, context)] if node.name == 'br'

          if node.name == 'bc-attachment' && node['content-type'] == 'application/vnd.basecamp.mention'
            return [mention_span(node, annotations, link, context)]
          end

          new_anno = annotations.dup
          new_link = link

          case node.name
          when 'strong', 'b'
            new_anno[:bold] = true
          when 'em', 'i'
            new_anno[:italic] = true
          when 'u'
            new_anno[:underline] = true
          when 's', 'strike'
            new_anno[:strikethrough] = true
          when 'code'
            new_anno[:code] = true
          when 'a'
            href = node['href']
            new_link = href if href&.strip&.match?(URI::DEFAULT_PARSER.make_regexp)
          end

          out = []
          node.children.each do |child|
            out.concat process_node(child, new_anno, new_link, context)
          end
          out
        else
          []
        end
      end

      def newline_span(annotations, link, context)
        span = NotionSpan.new(text: "\n", annotations: annotations, link: link)
        Logger.debug("[RichText] produced newline => #{span.debug_description} (#{context})")
        span
      end

      def mention_span(node, annotations, link, context)
        figure = node.at_css('figure')
        caption = figure&.at_css('figcaption')&.text&.strip || "Unknown"
        text = "👤 #{caption}"
        Logger.debug("[RichText] parsed mention span => #{text.inspect} (#{context})")
        NotionSpan.new(text: text, annotations: annotations, link: link)
      end

      def merge_consecutive_spans(spans)
        return [] if spans.empty?
        merged = [spans.first]
        spans.each_cons(2) do |(_, curr)|
          if merged.last.merge_if_compatible!(curr)
            # merged
          else
            merged << curr
          end
        end
        merged
      end

      def trim_trailing_newlines(spans)
        return if spans.empty?
        last_span = spans[-1]
        if last_span.content.match?(/\n+$/)
          last_span.content = last_span.content.sub(/\n+$/, "")
          spans.pop if last_span.content.empty?
        end
      end

      def chunk_spans(spans)
        results = []
        spans.each do |span|
          text = span.content
          if text.size <= MAX_NOTION_TEXT_LENGTH
            results << span
          else
            offset = 0
            while offset < text.size
              slice = text[offset, MAX_NOTION_TEXT_LENGTH]
              offset += MAX_NOTION_TEXT_LENGTH
              new_span = NotionSpan.new(text: slice, annotations: span.annotations.dup, link: span.link)
              results << new_span
            end
          end
        end
        results
      end
    end
  end
end
