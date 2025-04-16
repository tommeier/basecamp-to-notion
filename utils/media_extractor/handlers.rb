# utils/media_extractor/handlers.rb

require_relative './constants'
require_relative './helpers'      # => Utils::MediaExtractor::Helpers
require_relative './logger'
require_relative './resolver'     # => for resolve_basecamp_url, embeddable_media_url?, basecamp_asset_url?
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

      # -------------------------------------------------------
      # Recursively handle
      # -------------------------------------------------------
      def self.handle_node_recursive(node, context, parent_page_id, notion_blocks, embed_blocks)
        return if node.comment?

        if node.name.downcase == 'figcaption'
          debug "[handle_node_recursive] forcibly skipping <figcaption> (#{context})"
          return
        end

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

      # -------------------------------------------------------
      # Switch on node type
      # -------------------------------------------------------
      def self.handle_node(node, context, notion_blocks, embed_blocks)
        return if inside_bc_attachment?(node) && node.name != 'bc-attachment'

        case node.name.downcase
        when 'div', 'p'
          # => already handled by handle_node_recursive
        when 'br'
          # => skip
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
          debug "[handle_node] forcibly skipping <figcaption> (#{context})"
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
        end
      end

      # -------------------------------------------------------
      # <div> or <p>
      # -------------------------------------------------------
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

        # if single text is only whitespace, skip
        if rich_text.size == 1 && rich_text[0][:type] == 'text'
          text_content = rich_text[0].dig(:text, :content).to_s
          return [] if text_content.strip.empty?
        end

        block = {
          object: 'block',
          type: 'paragraph',
          paragraph: { rich_text: rich_text }
        }
        debug "[process_div_or_paragraph] built => #{block.inspect} (#{context})"
        blocks << block

        blocks
      end

      def self.empty_or_whitespace_div?(node)
        content = node.inner_html.strip
        return true if content.empty? || content.downcase == '<br>'
        return true if content.gsub('&nbsp;', '').strip.empty?
        false
      end

      # -------------------------------------------------------
      # bc-attachment
      # -------------------------------------------------------
      def self.process_bc_attachment(node, context)
        blocks = []
        raw_url = node['url'] || node['href'] || node['src']
        # if there's a figure inside => process_figure
        return process_figure(node, context) if node.at_css('figure')

        caption = node.at_css('figcaption')&.text&.strip || node['caption']
        caption = caption.gsub(/\s+/, ' ') if caption

        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)

        if !resolved_url || Resolver.basecamp_asset_url?(resolved_url)
          return ::Notion::Helpers.basecamp_asset_fallback_blocks(resolved_url || raw_url, caption, context)
        elsif resolved_url.end_with?('.pdf')
          return [Helpers.pdf_file_block(resolved_url, context)]
        elsif Resolver.embeddable_media_url?(resolved_url)
          # => e.g. giphy => embed as image
          blocks << {
            object: 'block',
            type: 'image',
            image: {
              type: 'external',
              external: { url: resolved_url }
            }
          }
          blocks << ::Notion::Helpers.text_block("Caption: #{caption}", context).first if caption && !caption.empty?
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

      # -------------------------------------------------------
      # figure
      # -------------------------------------------------------
      def self.process_figure(node, context)
        blocks = []
        img = node.at_css('img')
        raw_url = img&.[]('src')&.strip

        # remove figcaption from DOM
        caption_node = node.at_css('figcaption')
        caption = caption_node&.text&.strip
        caption_node&.remove

        # remove leftover text nodes
        node.xpath('text()').each { |txt| txt.remove if txt.text.strip.empty? }

        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)

        if !resolved_url || Resolver.basecamp_asset_url?(resolved_url)
          blocks.concat ::Notion::Helpers.basecamp_asset_fallback_blocks(resolved_url || raw_url, caption, context)
        elsif resolved_url.end_with?('.pdf')
            blocks << Helpers.pdf_file_block(resolved_url, context)
        elsif Resolver.embeddable_media_url?(resolved_url)
          # => e.g. giphy => embed as image
          blocks << {
            object: 'block',
            type: 'image',
            image: {
              type: 'external',
              external: { url: resolved_url }
            }
          }
          blocks << ::Notion::Helpers.text_block("Caption: #{caption}", context).first if caption && !caption.empty?
        else
          blocks << Helpers.build_embed_block(resolved_url, context)
        end

        blocks
      end

      # -------------------------------------------------------
      # code block
      # -------------------------------------------------------
      def self.process_code_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?

        [{
          object: 'block',
          type: 'code',
          code: {
            rich_text: rich_text,
            language: 'plain text'
          }
        }]
      end

      # -------------------------------------------------------
      # headings
      # -------------------------------------------------------
      def self.process_heading_block(node, context, level:)
        text = node.text.strip
        return [] if text.empty?

        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?

        [{
          object: 'block',
          type: "heading_#{level}",
          "heading_#{level}".to_sym => { rich_text: rich_text }
        }]
      end

      # -------------------------------------------------------
      # quote
      # -------------------------------------------------------
      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?

        [{
          object: 'block',
          type: 'quote',
          quote: { rich_text: rich_text }
        }]
      end

      # -------------------------------------------------------
      # hr => divider
      # -------------------------------------------------------
      def self.process_divider_block
        { object: 'block', type: 'divider', divider: {} }
      end

      # -------------------------------------------------------
      # UL / OL => lists
      # -------------------------------------------------------
      def self.process_list(node, list_type, context)
        blocks = []
        embeds = []

        node.css('li').each do |li|
          li_html = li.inner_html.strip
          li_frag = Nokogiri::HTML.fragment(li_html)
          li_rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(li_frag, context)
          next if li_rich_text.empty?

          block = {
            object: 'block',
            type: (list_type == 'unordered' ? 'bulleted_list_item' : 'numbered_list_item'),
            (list_type == 'unordered' ? :bulleted_list_item : :numbered_list_item) => {
              rich_text: li_rich_text
            }
          }
          blocks << block
        end

        [blocks, embeds]
      end
    end
  end
end
