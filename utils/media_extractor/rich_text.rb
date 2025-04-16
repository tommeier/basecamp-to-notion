# utils/media_extractor/rich_text.rb

require 'nokogiri'
require_relative './notion_span'
require_relative './logger'
require 'cgi'

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

        sanitize_links!(merged, context)

        chunked = chunk_spans(merged)

        Logger.debug("[RichText] final chunked => #{chunked.map(&:debug_description)} (#{context})")

        chunked.map(&:to_notion_rich_text)
      rescue => e
        Logger.error("[RichText] error: #{e.message}\n#{e.backtrace.join("\n")}")
        []
      end


      # ✅ Safely handle plain string (e.g., for <pre>, headings, quotes)
      def extract_rich_text_from_string(str, context = nil)
        return [] if str.nil? || str.empty?
        safe_html = "<div>#{CGI.escapeHTML(str)}</div>"
        fragment = Nokogiri::HTML.fragment(safe_html)
        extract_rich_text_from_fragment(fragment, context)
      end

      private

      def process_node(node, annotations, link, context)
        return [] if node.comment?

        if node.text?
          return [] if node.text.strip.empty?
          return [NotionSpan.new(text: node.text, annotations: annotations, link: link)]

        elsif node.element?
          return [newline_span(annotations, link, context)] if node.name == 'br'

          if node.name == 'bc-attachment' && node['content-type'] == 'application/vnd.basecamp.mention'
            return [mention_span(node, annotations, link, context)]
          end

          new_anno = annotations.dup
          new_link = link

          case node.name
          when 'strong', 'b' then new_anno[:bold] = true
          when 'em', 'i'     then new_anno[:italic] = true
          when 'u'           then new_anno[:underline] = true
          when 's', 'strike' then new_anno[:strikethrough] = true
          when 'code'        then new_anno[:code] = true
          when 'a'
            href = node['href']
            new_link = href if href&.strip&.match?(URI::DEFAULT_PARSER.make_regexp)
          end

          out = []
          node.children.each { |child| out.concat process_node(child, new_anno, new_link, context) }
          out
        else
          []
        end
      end

      def newline_span(annotations, link, context)
        NotionSpan.new(text: "\n", annotations: annotations, link: link)
      end

      def mention_span(node, annotations, link, context)
        caption = node.at_css('figcaption')&.text&.strip || "Unknown"
        NotionSpan.new(text: "👤 #{caption}", annotations: annotations, link: link)
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
        last = spans.last
        if last.content.match?(/\n+$/)
          last.content = last.content.sub(/\n+$/, "")
          spans.pop if last.content.empty?
        end
      end

      def chunk_spans(spans)
        spans.flat_map do |span|
          text = span.content
          if text.size <= MAX_NOTION_TEXT_LENGTH
            [span]
          else
            text.chars.each_slice(MAX_NOTION_TEXT_LENGTH).map do |slice|
              NotionSpan.new(text: slice.join, annotations: span.annotations.dup, link: span.link)
            end
          end
        end
      end

      def sanitize_links!(spans, context)
        spans.each do |span|
          next unless span.link.is_a?(String)

          uri = URI.parse(span.link) rescue nil
          unless uri&.scheme&.match?(/^https?$/)
            Logger.warn("⚠️ Removing or fixing invalid URL in span: #{span.link.inspect} (#{context})")
            if span.link.start_with?("www.")
              span.link = "https://#{span.link}"
            else
              span.link = nil
            end
          end
        end
      end

    end
  end
end
