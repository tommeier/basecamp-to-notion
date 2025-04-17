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

      def self.handle_node_recursive(node, context, parent_page_id, notion_blocks, embed_blocks, seen_nodes = Set.new)
        return if node.comment?
        return if seen_nodes.include?(node.object_id)

        # Skip to allow for nested lists
        if node.name.downcase == 'li' || node.ancestors.any? { |a| a.name == 'li' }
          debug "↪️ [handle_node_recursive] Skipping <li> or child-of-li node: <#{node.name}> (#{context})"
          return
        end

        # Track seen to avoid duplicates
        seen_nodes << node.object_id

        debug "[handle_node_recursive] visiting <#{node.name}> (#{context})"

        # Handle directly due to wrapping html objects
        case node.name.downcase
        when 'div', 'p'
          notion_blocks.concat process_div_or_paragraph(node, context)
          return
        when 'ul', 'ol'
          nested_blocks = build_nested_list_blocks(node, context, seen_nodes)
          notion_blocks.concat(nested_blocks)
          return
        end

        handle_node(node, context, notion_blocks, embed_blocks, seen_nodes)
        return if SKIP_CHILDREN_NODES.include?(node.name)

        node.children.each do |child|
          next unless child.element?
          handle_node_recursive(child, context, parent_page_id, notion_blocks, embed_blocks, seen_nodes)
        end
      end


      def self.handle_node(node, context, notion_blocks, embed_blocks, seen_nodes = Set.new)
        return if inside_bc_attachment?(node) && node.name != 'bc-attachment'

        case node.name.downcase
        when 'div', 'p', 'ul', 'ol', 'li'
          # Handled in handle_node_recursive
        when 'br'
          # => skip
          return
        when 'bc-attachment'
          # Skip here — handled inline in RichText as emoji fallback with name
          # Notion won't allow small inline images for the avatars
          return if node['content-type'] == 'application/vnd.basecamp.mention'

          blocks = process_bc_attachment(node, context)
          validate_blocks!(blocks, 'process_bc_attachment', node, context)
          notion_blocks.concat(blocks)
        when 'figure'
          blocks = process_figure(node, context)
          validate_blocks!(blocks, 'process_figure', node, context)
          notion_blocks.concat(blocks)
        when 'figcaption'
          debug "[handle_node] forcibly skipping <figcaption> (#{context})"
        when 'pre'
          blocks = process_code_block(node, context)
          validate_blocks!(blocks, 'process_code_block', node, context)
          notion_blocks.concat(blocks)
        when 'h1'
          blocks = process_heading_blocks(node, context, level: 1)
          validate_blocks!(blocks, 'process_heading_blocks h1', node, context)
          notion_blocks.concat(blocks)
        when 'h2'
          blocks = process_heading_blocks(node, context, level: 2)
          validate_blocks!(blocks, 'process_heading_blocks h2', node, context)
          notion_blocks.concat(blocks)
        when 'h3'
          blocks = process_heading_blocks(node, context, level: 3)
          validate_blocks!(blocks, 'process_heading_blocks h3', node, context)
          notion_blocks.concat(blocks)
        when 'blockquote'
          blocks = process_quote_block(node, context)
          validate_blocks!(blocks, 'process_quote_block', node, context)
          notion_blocks.concat(blocks)
        when 'hr'
          notion_blocks << Helpers.divider_block
        when 'iframe'
          embed_blocks << Helpers.build_embed_block(node['src'], context) if node['src']
        else
          debug "[handle_node] Unhandled node type: #{node.name} (#{context})"
        end
      end

      def self.process_div_or_paragraph(node, context)
        return [Notion::Helpers.empty_paragraph_block] if empty_or_whitespace_div?(node)

        html_str = node.inner_html
        debug "[process_div_or_paragraph] => #{html_str.inspect} (#{context})"
        parsed_fragment = Nokogiri::HTML.fragment(html_str)
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(parsed_fragment, context)
        return [] if rich_text.empty?

        [
          {
            object: 'block',
            type: 'paragraph',
            paragraph: { rich_text: rich_text }
          }
        ]
      end

      def self.empty_or_whitespace_div?(node)
        content = node.inner_html.strip
        return true if content.empty? || content.downcase == '<br>'
        return true if content.gsub('&nbsp;', '').strip.empty?
        false
      end

      def self.build_nested_list_blocks(list_node, context, seen_nodes)
        blocks = []

        list_node.xpath('./li').each do |li_node|
          next if seen_nodes.include?(li_node.object_id)
          seen_nodes << li_node.object_id

          content_nodes = li_node.children.reject { |child| %w[ul ol].include?(child.name.downcase) }
          nested_lists  = li_node.children.select { |child| %w[ul ol].include?(child.name.downcase) }

          content_html = content_nodes.map(&:to_html).join.strip
          fragment = Nokogiri::HTML.fragment(content_html)
          rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(fragment, context)

          next if rich_text.empty?

          block_type = list_node.name.downcase == 'ol' ? 'numbered_list_item' : 'bulleted_list_item'

          # Create valid block with children inside type container
          block = {
            object: 'block',
            type: block_type,
            block_type.to_sym => {
              rich_text: rich_text
            }
          }

          nested_blocks = nested_lists.flat_map do |sublist|
            build_nested_list_blocks(sublist, context, seen_nodes)
          end

          if nested_blocks.any?
            if li_node.ancestors.count { |a| a.name == 'li' } >= 2
              log "⚠️ [build_nested_list_blocks] Skipping deeper nesting for li due to Notion limit of a depth of 3 (#{context})"
              # Promote instead of nesting - this puts it above where it should go, but its easier
              blocks.concat(nested_blocks)
            else
              block[block_type.to_sym][:children] = nested_blocks
            end
          end

          blocks << block
        end

        blocks
      end

      def self.validate_blocks!(blocks, origin, node, context)
        # Optional: add JSON structure validation here
        # Unomment this for deep validation of blocks in case of errors
        # unless blocks.is_a?(Array) && blocks.all? { |b| b.is_a?(Hash) && b[:object] == 'block' }
        #   warn "❌ [#{origin}] produced invalid block(s): #{blocks.inspect}"
        #   warn "🧩 From node: #{node.to_html.strip} (#{context})"
        #   raise "Invalid block from #{origin}"
        # end
      end

      def self._process_bc_attachment_or_figure(node, raw_url, context)
        return [] if raw_url.nil? || raw_url.empty?
        blocks = []

        caption_node = node.at_css('figcaption')
        caption = caption_node&.text&.strip
        caption_node&.remove

        # remove figcaption from DOM (removes duplicates on traversal)
        node.xpath('text()').each { |txt| txt.remove if txt.text.strip.empty? }

        # remove leftover text nodes
        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)

        if !resolved_url || Resolver.basecamp_asset_url?(resolved_url)
          return ::Notion::Helpers.basecamp_asset_fallback_blocks(resolved_url || raw_url, caption, context)
        elsif resolved_url.end_with?('.pdf')
          return [Helpers.pdf_file_block(resolved_url, context)]
        elsif Resolver.embeddable_media_url?(resolved_url)
          blocks << ::Notion::Helpers.image_block(resolved_url, caption)
          blocks += ::Notion::Helpers.text_blocks("Caption: #{caption}", context) if caption && !caption.empty?
        else
          blocks << Helpers.build_embed_block(resolved_url, context)
          blocks += ::Notion::Helpers.text_blocks("Caption: #{caption}", context) if caption && !caption.empty?
        end
        blocks.compact
      end

      def self.process_bc_attachment(node, context)
        # if there's a figure inside => process_figure
        return process_figure(node, context) if node.at_css('figure')

        raw_url = (node['url'] || node['href'] || node['src'])&.strip
        _process_bc_attachment_or_figure(node, raw_url, context)
      end

      def self.process_figure(node, context)
        img = node.at_css('img')
        raw_url = img&.[]('src')&.strip
        _process_bc_attachment_or_figure(node, raw_url, context)
      end

      def self.process_code_block(node, context)
        text = node.text.strip
        return [] if text.empty?
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        [{ object: 'block', type: 'code', code: { rich_text: rich_text, language: 'plain text' } }]
      end

      def self.process_heading_blocks(node, context, level:)
        text = node.text.strip
        return [] if text.empty?
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        [{ object: 'block', type: "heading_#{level}", "heading_#{level}".to_sym => { rich_text: rich_text } }]
      end

      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        [{ object: 'block', type: 'quote', quote: { rich_text: rich_text } }]
      end

      def self.inside_bc_attachment?(node)
        node.ancestors.any? { |ancestor| ancestor.name == 'bc-attachment' }
      end
    end
  end
end
