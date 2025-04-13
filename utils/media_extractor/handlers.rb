# utils/media_extractor/handlers.rb

require_relative './constants'
require_relative './helpers'
require_relative './logger'
require_relative './resolver'
require_relative './rich_text'

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
        # ✅ Skip text nodes entirely — they are already handled in process_div_or_paragraph fragments
        if node.text?
          debug "🚫 [handle_node_recursive] Skipping text node: '#{node.text.strip}' (#{context})"
          return
        end

        # ✅ Process div/p nodes in bulk to avoid child duplication.
        if %w[div p].include?(node.name)
          handle_node(node, context, parent_page_id, notion_blocks, embed_blocks)
          return
        end

        handle_node(node, context, parent_page_id, notion_blocks, embed_blocks)

        # 🚫 Do not recurse into children of these nodes
        return if SKIP_CHILDREN_NODES.include?(node.name)

        node.children.each do |child|
          next unless child.element?
          handle_node_recursive(child, context, parent_page_id, notion_blocks, embed_blocks)
        end
      end

      def self.handle_node(node, context, parent_page_id, notion_blocks, embed_blocks)
        if inside_bc_attachment?(node) && node.name != 'bc-attachment'
          debug "🚫 [handle_node] Skipping node inside <bc-attachment>: <#{node.name}> (#{context})"
          return
        end

        case node.name
        when 'div', 'p'
          notion_blocks.concat process_div_or_paragraph(node, context, parent_page_id)
        when 'br'
          notion_blocks << Helpers.empty_paragraph_block
        when 'bc-attachment'
          notion_blocks.concat process_bc_attachment(node, context, parent_page_id)
        when 'ul', 'ol'
          list_blocks, list_embeds = process_list(node, node.name == 'ul' ? 'unordered' : 'ordered', context, parent_page_id)
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
          notion_blocks << process_divider_block(context)
        when 'iframe'
          if node['src']
            embed_blocks << Helpers.build_embed_block(node['src'], context)
          else
            warn "⚠️ [handle_node] iframe without src attribute (#{context})"
          end
        when 'figcaption'
          notion_blocks.concat process_figcaption(node, context)
        else
          debug "⚠️ [handle_node] Unhandled node <#{node.name}> — treating as paragraph (#{context})"
          notion_blocks.concat process_div_or_paragraph(node, context, parent_page_id)
        end
      end

      def self.process_div_or_paragraph(node, context, parent_page_id)
        blocks = []
        fragments = []
        current_fragment = []

        node.children.each do |child|
          if child.name == 'br'
            fragments << current_fragment unless current_fragment.empty?
            current_fragment = []
          else
            current_fragment << child
          end
        end
        fragments << current_fragment unless current_fragment.empty?

        debug "🧩 [process_div_or_paragraph] (#{context}): #{fragments.size} fragments"

        fragments.each_with_index do |fragment, idx|
          rich_text, embed_blocks = ::Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(fragment, context, parent_page_id)
          next if rich_text.compact.empty?

          rich_text_chunks = Helpers.chunk_rich_text(rich_text)
          Logger.debug_chunk_summary(rich_text_chunks, context: context, label: "Div/P Fragment #{idx + 1}")

          rich_text_chunks.each_with_index do |chunk, chunk_idx|
            next if chunk.compact.empty?

            block = {
              object: "block",
              type: "paragraph",
              paragraph: { rich_text: chunk.compact }
            }
            debug "🧩 [process_div_or_paragraph] Built block #{idx + 1}.#{chunk_idx + 1} (#{context}): #{block.to_json[0..500]}"
            blocks << block
          end

          blocks.concat(embed_blocks.compact) if embed_blocks.any?
        end

        blocks
      end

      def self.process_bc_attachment(node, context, parent_page_id)
        blocks = []

        basecamp_href = Helpers.clean_url(node['href'])
        filename = (node['filename'] || basecamp_href).to_s.strip
        figcaption_text = node.at_css('figcaption')&.text&.strip

        if basecamp_href
          segment = Helpers.text_segment("Basecamp asset: 🔗 #{filename}", link: basecamp_href)
          blocks << {
            object: "block",
            type: "paragraph",
            paragraph: { rich_text: [segment] }
          }
          log "🖼️ [process_bc_attachment] Added Basecamp asset link block: #{basecamp_href} (#{context})"
        else
          warn "⚠️ [process_bc_attachment] bc-attachment missing href attribute (#{context})"
        end

        if figcaption_text && !figcaption_text.empty?
          blocks << {
            object: "block",
            type: "paragraph",
            paragraph: { rich_text: [{ type: "text", text: { content: figcaption_text } }] }
          }
          log "🖼️ [process_bc_attachment] Added figcaption text block: #{figcaption_text} (#{context})"
        end

        blocks
      end

      def self.process_code_block(node, context)
        code_text = node.text.strip
        return [] if code_text.empty?

        chunks = Helpers.chunk_rich_text([Helpers.text_segment(code_text)].compact)
        Logger.debug_chunk_summary(chunks, context: context, label: "Code block")

        chunks.map.with_index do |chunk, idx|
          {
            object: "block",
            type: "code",
            code: { rich_text: chunk.compact, language: "plain text" }
          }.tap do |block|
            debug "🧩 [process_code_block] Built code block chunk #{idx + 1}/#{chunks.size} (#{context}): #{block.to_json[0..500]}"
          end
        end
      end

      def self.process_heading_block(node, context, level:)
        heading_text = node.text.strip
        return [] if heading_text.empty?

        chunks = Helpers.chunk_rich_text([Helpers.text_segment(heading_text)].compact)
        Logger.debug_chunk_summary(chunks, context: context, label: "Heading level #{level}")

        chunks.map.with_index do |chunk, idx|
          {
            object: "block",
            type: "heading_#{level}",
            "heading_#{level}": { rich_text: chunk.compact }
          }.tap do |block|
            debug "🧩 [process_heading_block] Built heading_#{level} block chunk #{idx + 1}/#{chunks.size} (#{context}): #{block.to_json[0..500]}"
          end
        end
      end

      def self.process_quote_block(node, context)
        quote_text = node.text.strip
        return [] if quote_text.empty?

        chunks = Helpers.chunk_rich_text([Helpers.text_segment(quote_text)].compact)
        Logger.debug_chunk_summary(chunks, context: context, label: "Quote block")

        chunks.map.with_index do |chunk, idx|
          {
            object: "block",
            type: "quote",
            quote: { rich_text: chunk.compact }
          }.tap do |block|
            debug "🧩 [process_quote_block] Built quote block chunk #{idx + 1}/#{chunks.size} (#{context}): #{block.to_json[0..500]}"
          end
        end
      end

      def self.process_divider_block(context)
        block = {
          object: "block",
          type: "divider",
          divider: {}
        }
        debug "🧩 [process_divider_block] Built divider block (#{context})"
        block
      end

      def self.process_figcaption(node, context)
        caption_text = node.text.strip
        return [] if caption_text.empty?

        chunks = Helpers.chunk_rich_text([Helpers.text_segment(caption_text)].compact)
        Logger.debug_chunk_summary(chunks, context: context, label: "Figcaption block")

        chunks.map.with_index do |chunk, idx|
          {
            object: "block",
            type: "paragraph",
            paragraph: { rich_text: chunk.compact }
          }.tap do |block|
            debug "🧩 [process_figcaption] Built figcaption block chunk #{idx + 1}/#{chunks.size} (#{context}): #{block.to_json[0..500]}"
          end
        end
      end

      def self.process_list(node, list_type, context, parent_page_id)
        blocks = []
        embed_blocks = []

        node.css('li').each_with_index do |li, idx|
          rich_text, li_embeds = ::Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(li.children, context, parent_page_id)
          next if rich_text.compact.empty?

          rich_text_chunks = Helpers.chunk_rich_text(rich_text)
          Logger.debug_chunk_summary(rich_text_chunks, context: context, label: "List Item #{idx + 1}")

          rich_text_chunks.each_with_index do |chunk, chunk_idx|
            block = {
              object: "block",
              type: list_type == 'unordered' ? "bulleted_list_item" : "numbered_list_item",
              (list_type == 'unordered' ? :bulleted_list_item : :numbered_list_item) => {
                rich_text: chunk.compact
              }
            }

            debug "🧩 [process_list] Built list block #{idx + 1}.#{chunk_idx + 1} (#{context}): #{block.to_json[0..500]}"
            blocks << block
          end

          embed_blocks.concat(li_embeds.compact) if li_embeds.any?
        end

        [blocks.compact, embed_blocks.compact]
      end
    end
  end
end
