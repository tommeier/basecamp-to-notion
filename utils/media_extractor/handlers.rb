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
          # Already handled in handle_node_recursive
        when 'br'
          # no separate block for <br>
        when 'bc-attachment'
          notion_blocks.concat process_bc_attachment(node, context)
        when 'ul', 'ol'
          list_blocks, list_embeds = process_list(node, node.name == 'ul' ? 'unordered' : 'ordered', context)
          notion_blocks.concat(list_blocks)
          embed_blocks.concat(list_embeds)
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
        when 'figcaption'
          notion_blocks.concat process_figcaption_dedup(node, context)
        else
          # fallback for inline tags
        end
      end

      def self.process_div_or_paragraph(node, context)
        blocks = []

        # If the node is empty except for <br> or whitespace, create a blank paragraph block
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
        # If it has no real text except <br> or whitespace, treat as blank
        # e.g. <div><br></div> or <p>&nbsp;</p>
        content = node.inner_html.strip
        # if content is empty or just <br> or &nbsp;
        return true if content == '' || content.downcase == '<br>' || content.gsub('&nbsp;', '').strip == ''
        false
      end

      def self.process_figcaption_dedup(node, context)
        text = node.text.strip
        return [] if text.empty?

        # Check parent's text or grandparent's text for duplication
        par_text = node.parent&.text&.strip
        gp_text  = node.parent&.parent&.text&.strip

        if [par_text, gp_text].compact.any? { |t| t == text }
          debug "[process_figcaption_dedup] skipping figcaption (duplicate) => #{text.inspect} (#{context})"
          return []
        end

        [{
          object: 'block',
          type: 'paragraph',
          paragraph: { rich_text: [Helpers.text_segment(text)] }
        }]
      end

      def self.process_bc_attachment(node, context)
        blocks = []
        href = Helpers.clean_url(node['href'])
        filename = (node['filename'] || href).to_s.strip
        figcaption_text = node.at_css('figcaption')&.text&.strip

        if href
          blocks << {
            object: 'block',
            type: 'paragraph',
            paragraph: {
              rich_text: [Helpers.text_segment("Basecamp asset: 🔗 #{filename}", link: href)]
            }
          }
        end

        if figcaption_text && !figcaption_text.empty?
          blocks << {
            object: 'block',
            type: 'paragraph',
            paragraph: {
              rich_text: [Helpers.text_segment(figcaption_text)]
            }
          }
        end

        blocks
      end

      def self.process_code_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        [
          {
            object: 'block',
            type: 'code',
            code: { rich_text: [Helpers.text_segment(text)], language: 'plain text' }
          }
        ]
      end

      def self.process_heading_block(node, context, level:)
        text = node.text.strip
        return [] if text.empty?

        [
          {
            object: 'block',
            type: "heading_#{level}",
            "heading_#{level}".to_sym => {
              rich_text: [Helpers.text_segment(text)]
            }
          }
        ]
      end

      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        [
          {
            object: 'block',
            type: 'quote',
            quote: { rich_text: [Helpers.text_segment(text)] }
          }
        ]
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
