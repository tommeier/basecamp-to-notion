# utils/media_extractor/handlers.rb

require_relative './constants'
require_relative './helpers'
require_relative './logger'
require_relative './resolver'
require_relative './rich_text'
require 'set'

module Utils
  module MediaExtractor
    module Handlers
      extend ::Utils::Logging
      extend ::Utils::MediaExtractor::Helpers
      extend ::Utils::MediaExtractor::Resolver

      SKIP_CHILDREN_NODES = ['bc-attachment']

      def self.inside_bc_attachment?(node)
        node.ancestors.any? { |ancestor| ancestor.name == 'bc-attachment' }
      end

      def self.handle_node_recursive(node, context, parent_page_id, notion_blocks, embed_blocks)
        return if node.comment?

        if %w[div p].include?(node.name)
          notion_blocks.concat process_div_or_paragraph(node, context)
          return
        end

        handle_node(node, context, notion_blocks, embed_blocks)
        return if SKIP_CHILDREN_NODES.include?(node.name)

        node.children.each do |child|
          next unless child.element?
          handle_node_recursive(child, context, parent_page_id, notion_blocks, embed_blocks)
        end
      end

      def self.handle_node(node, context, notion_blocks, embed_blocks)
        return if inside_bc_attachment?(node) && node.name != 'bc-attachment'

        case node.name
        when 'div', 'p'
          # already handled by handle_node_recursive
        when 'br'
          # no separate block
        when 'bc-attachment'
          if node['content-type'] == 'application/vnd.basecamp.mention'
            # Skip here — handled inline in RichText as emoji fallback with name
            # Notion won't allow small inline images for the avatars
            return
          else
            notion_blocks.concat process_bc_attachment(node, context)
          end
        when 'figure'
          notion_blocks.concat process_figure(node, context)
        when 'figcaption'
          notion_blocks.concat process_figcaption_dedup(node, context)
        when 'ul', 'ol'
          lb, eb = process_list(node, node.name == 'ul' ? 'unordered' : 'ordered', context)
          notion_blocks.concat(lb)
          embed_blocks.concat(eb)
        when 'pre'
          notion_blocks.concat process_code_block(node, context)
        when 'h1'
          notion_blocks.concat process_heading_block(node, context, level: 1)
        when 'h2'
          notion_blocks.concat process_heading_block(node, context, level: 2)
        when 'h3'
          notion_blocks.concat process_heading_block(node, context, level: 3)
        when 'blockquote'
          notion_blocks.concat process_quote_block(node, context)
        when 'hr'
          notion_blocks << process_divider_block
        when 'iframe'
          embed_blocks << Helpers.build_embed_block(node['src'], context) if node['src']
        end
      end

      def self.process_div_or_paragraph(node, context)
        blocks = []

        if empty_or_whitespace_div?(node)
          blocks << Helpers.empty_paragraph_block
          return blocks
        end

        html_str = node.inner_html
        debug "[process_div_or_paragraph] => #{html_str.inspect} (#{context})"

        parsed_fragment = Nokogiri::HTML.fragment(html_str)
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(parsed_fragment, context)
        return blocks if rich_text.empty?

        block = {
          object: 'block',
          type: 'paragraph',
          paragraph: { rich_text: rich_text }
        }
        debug "[process_div_or_paragraph] built => #{block.inspect} (#{context})"
        blocks << block
      end

      def self.empty_or_whitespace_div?(node)
        content = node.inner_html.strip
        content.empty? || content.downcase == '<br>' || content.gsub('&nbsp;', '').strip.empty?
      end

      def self.process_bc_attachment(node, context)
        blocks = []
        raw_url = node['url'] || node['href'] || node['src']
        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)
        return blocks unless resolved_url

        caption = node.at_css('figcaption')&.text&.strip || node['caption']
        caption = caption.gsub(/\s+/, ' ') if caption

        if Resolver.basecamp_asset_url?(resolved_url)
          lines = ["Basecamp asset: 🔗 #{resolved_url}"]
          lines << "Caption: #{caption}" if caption && !caption.empty?
          spans = lines.flat_map.with_index do |line, idx|
            [Helpers.text_segment(line)] + (idx < lines.size - 1 ? [Helpers.text_segment("\n")] : [])
          end

          blocks << {
            object: 'block',
            type: 'paragraph',
            paragraph: { rich_text: spans }
          }
        else
          blocks << Helpers.build_embed_block(resolved_url, context)
          if caption && !caption.empty?
            blocks << {
              object: 'block',
              type: 'paragraph',
              paragraph: {
                rich_text: [Helpers.text_segment("Caption: #{caption}")]
              }
            }
          end
        end

        blocks
      end

      def self.process_figure(node, context)
        blocks = []
        img = node.at_css('img')
        raw_url = img&.[]('src')&.strip
        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)
        return blocks unless resolved_url

        caption = node.at_css('figcaption')&.text&.strip&.gsub(/\s+/, ' ')

        if Resolver.basecamp_asset_url?(resolved_url)
          lines = ["Basecamp asset: 🔗 #{resolved_url}"]
          lines << "Caption: #{caption}" if caption && !caption.empty?
          spans = lines.flat_map.with_index do |line, idx|
            [Helpers.text_segment(line)] + (idx < lines.size - 1 ? [Helpers.text_segment("\n")] : [])
          end

          blocks << {
            object: 'block',
            type: 'paragraph',
            paragraph: { rich_text: spans }
          }
        else
          blocks << Helpers.build_embed_block(resolved_url, context)
          if caption && !caption.empty?
            blocks << {
              object: 'block',
              type: 'paragraph',
              paragraph: {
                rich_text: [Helpers.text_segment("Caption: #{caption}")]
              }
            }
          end
        end

        blocks
      end

      def self.process_figcaption_dedup(node, context)
        txt = node.text.strip.gsub(/\s+/, ' ')
        return [] if txt.empty?

        parent_text = node.parent&.text&.strip&.gsub(/\s+/, ' ')
        gp_text = node.parent&.parent&.text&.strip&.gsub(/\s+/, ' ')

        if [parent_text, gp_text].compact.any? { |t| t == txt }
          debug "[process_figcaption_dedup] skipping duplicate figcaption => #{txt.inspect} (#{context})"
          return []
        end

        [{
          object: 'block',
          type: 'paragraph',
          paragraph: { rich_text: [Helpers.text_segment("Caption: #{txt}")] }
        }]
      end

      def self.process_code_block(node, context)
        text = node.text
        return [] if text.strip.empty?

        [{
          object: 'block',
          type: 'code',
          code: {
            rich_text: [Helpers.text_segment(text)],
            language: 'plain text'
          }
        }]
      end

      def self.process_heading_block(node, context, level:)
        text = node.text.strip
        return [] if text.empty?

        [{
          object: 'block',
          type: "heading_#{level}",
          "heading_#{level}".to_sym => {
            rich_text: [Helpers.text_segment(text)]
          }
        }]
      end

      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        [{
          object: 'block',
          type: 'quote',
          quote: { rich_text: [Helpers.text_segment(text)] }
        }]
      end

      def self.process_divider_block
        { object: 'block', type: 'divider', divider: {} }
      end

      def self.process_list(node, list_type, context)
        blocks = []
        embeds = []

        node.css('li').each do |li|
          li_frag = Nokogiri::HTML.fragment(li.inner_html)
          li_rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(li_frag, context)
          next if li_rich_text.empty?

          block = {
            object: 'block',
            type: (list_type == 'unordered' ? 'bulleted_list_item' : 'numbered_list_item'),
            (list_type == 'unordered' ? :bulleted_list_item : :numbered_list_item) => {
              rich_text: li_rich_text
            }
          }
          debug "[process_list] => #{block.inspect} (#{context})"
          blocks << block
        end

        [blocks, embeds]
      end
    end
  end
end
