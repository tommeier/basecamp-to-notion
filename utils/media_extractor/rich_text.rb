# utils/media_extractor/rich_text.rb
#
require 'nokogiri'
require_relative './constants'
require_relative './notion_span'
require_relative './logger'
require 'cgi'

module Utils
  module MediaExtractor
    module RichText
      extend self

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

        rich_texts = merged.flat_map(&:to_notion_rich_text)

        # Validate final lengths (debugging)
        rich_texts.each_with_index do |rtext, idx|
          length = rtext.dig(:text, :content)&.length || 0
          if length > MAX_NOTION_TEXT_LENGTH
            Logger.error("❌ Span too long after final chunking: #{length} chars (block #{idx}) (#{context})")
          end
        end

        Logger.debug("[RichText] final output => #{rich_texts.inspect} (#{context})")
        rich_texts
      rescue => e
        Logger.error("[RichText] error: #{e.message}\n#{e.backtrace.join("\n")}")
        []
      end

      def extract_rich_text_from_string(str, context = nil)
        return [] if str.nil? || str.empty?
        safe_html = "<div>#{CGI.escapeHTML(str)}</div>"
        fragment = Nokogiri::HTML.fragment(safe_html)
        extract_rich_text_from_fragment(fragment, context)
      end

      # Convenience wrapper to extract rich text from a single Nokogiri node
      def extract_rich_text_from_node(node, context = nil)
        return [] unless node
        fragment = Nokogiri::XML::DocumentFragment.parse("")
        fragment.add_child(node.dup)
        extract_rich_text_from_fragment(fragment, context)
      end

      # Convenience wrapper to extract rich text from all children of a Nokogiri node
      def extract_rich_text_from_node_children(node, context = nil)
        return [] unless node
        fragment = Nokogiri::XML::DocumentFragment.parse("")
        node.children.each { |child| fragment.add_child(child.dup) }
        extract_rich_text_from_fragment(fragment, context)
      end

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

      # Notion collapses inline newlines inside a paragraph; replacing <br> with a space keeps
      # expected separation between consecutive inline elements (e.g., bold text then a link).
      def newline_span(annotations, link, context)
        NotionSpan.new(text: " ", annotations: annotations, link: link)
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

      # Notion will block invalid URLs - but sometimes they are valid and being used for descriptions - show inline as text if so
      def sanitize_links!(spans, context)
        spans.each do |span|
          next unless span.link.is_a?(String)

          begin
            uri = URI.parse(span.link.strip)
            if !uri.scheme&.match?(/^https?$/) || uri.host.nil?
              Logger.warn("⚠️ Invalid link detected, converting to plain text: #{span.link.inspect} (#{context})")
              span.content += " (#{span.link})" unless span.content.include?(span.link)
              span.link = nil
            end
          rescue URI::InvalidURIError => e
            Logger.warn("⚠️ Invalid URI, converting to plain text (#{e.message}): #{span.link.inspect} (#{context})")
            span.content += " (#{span.link})" unless span.content.include?(span.link)
            span.link = nil
          end
        end
      end
    end
  end
end
