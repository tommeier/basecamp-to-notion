# utils/media_extractor/handlers.rb

require_relative './constants'
require_relative './helpers'      # => Utils::MediaExtractor::Helpers
require_relative './logger'
require_relative './resolver'     # => for resolve_basecamp_url, embeddable_media_url?, basecamp_asset_url?
require_relative './rich_text'
require 'set'
# New: enable private uploading for Basecamp private assets
require_relative '../../notion/private_upload'

module Utils
  module MediaExtractor
    module Handlers
      extend ::Utils::Logging
      extend ::Utils::MediaExtractor::Helpers
      extend ::Utils::MediaExtractor::Resolver

      unless defined?(@handlers_logged)
        log "✅ [MediaExtractor::Handlers] Image/media extraction handlers loaded and ready"
        @handlers_logged = true
      end

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
        when 'table'
          notion_blocks.concat process_table(node, context)
          return
        when 'details'
          notion_blocks.concat process_details_toggle(node, context)
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
        when 'table'
          blocks = process_table(node, context)
          validate_blocks!(blocks, 'process_table', node, context)
          notion_blocks.concat(blocks)
        when 'details'
          blocks = process_details_toggle(node, context)
          validate_blocks!(blocks, 'process_details_toggle', node, context)
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
        # Return simple paragraph if purely whitespace
        return [Notion::Helpers.empty_paragraph_block] if empty_or_whitespace_div?(node)

        blocks                 = []
        current_inline_group   = []
        seen_nodes             = Set.new

        # Local helper – converts a collected inline group to paragraph notion blocks
        build_paragraph_blocks = lambda do |inline_nodes|
          next if inline_nodes.empty?

          inline_html      = inline_nodes.map(&:to_html).join
          frag             = Nokogiri::HTML::DocumentFragment.parse(inline_html)
          rich_text_spans  = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(frag, context)
          next if rich_text_spans.empty?

          Helpers.chunk_rich_text(rich_text_spans).each do |chunk|
            blocks << {
              object: 'block',
              type:   'paragraph',
              paragraph: { rich_text: chunk }
            }
          end
        end

        node.children.each do |child|
          # Treat application/vnd.basecamp.mention inline – keep in inline group
          if child.element? && child.name == 'bc-attachment' && child['content-type'] != 'application/vnd.basecamp.mention'
            # Flush any pending inline nodes before the attachment
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []

            # Process the attachment as its own block(s)
            blocks.concat(process_bc_attachment(child, context))
          # Handle nested list structures that occasionally appear inside <div>/<p>
          elsif child.element? && %w[ul ol].include?(child.name.downcase)
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []

            blocks.concat(build_nested_list_blocks(child, context, seen_nodes))
          # Handle unexpected figure or heading nodes inside div/p
          elsif child.element? && child.name.downcase == 'figure'
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat(process_figure(child, context))
          elsif child.element? && %w[h1 h2 h3].include?(child.name.downcase)
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            level = child.name[1].to_i
            blocks.concat(process_heading_blocks(child, context, level: level))
          else
            current_inline_group << child
          end
        end

        # Flush trailing inline group if present
        build_paragraph_blocks.call(current_inline_group)

        blocks.compact
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

          # Detect Basecamp checklist (checkbox) pattern
          if li_node['data-checked'] || li_node['class'].to_s.downcase.include?('checkbox') || li_node.at_css('input[type="checkbox"]')
            block_type = 'to_do'
            checked    = li_node['data-checked'] == 'true' || li_node.at_css('input[type="checkbox"][checked]')
          else
            block_type = list_node.name.downcase == 'ol' ? 'numbered_list_item' : 'bulleted_list_item'
          end

          block = {
            object: 'block',
            type:   block_type,
            block_type.to_sym => {
              rich_text: rich_text,
            }
          }

          block[block_type.to_sym][:checked] = checked if block_type == 'to_do'

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

        # -----------------------------
        # Attempt private upload if the asset is still private or unresolved
        # -----------------------------
        if (!resolved_url || Resolver.basecamp_asset_url?(resolved_url) || Resolver.basecamp_cdn_url?(resolved_url)) && defined?(Notion::PrivateUpload) && Notion::PrivateUpload.enabled?
          uploaded_url = Notion::PrivateUpload.upload_from_url(raw_url, context)
          resolved_url = uploaded_url if uploaded_url && !uploaded_url.empty?
        end

        # Fallback: if still a time-limited Basecamp URL (preview/storage or CDN) or unresolved => yellow call-out
        if resolved_url.nil? || Resolver.basecamp_asset_url?(resolved_url) || Resolver.basecamp_cdn_url?(resolved_url)
          return ::Notion::Helpers.basecamp_asset_fallback_blocks(resolved_url || raw_url, caption, context)
        elsif resolved_url.end_with?('.pdf')
          pdf_block = Helpers.pdf_file_block(resolved_url, context)
          caption_blocks = caption && !caption.empty? ? Notion::Helpers.text_blocks("📄 #{caption}", context) : []
          return [pdf_block] + caption_blocks
        elsif node['content-type'].to_s.start_with?('video/') || resolved_url.match?(/\.(mp4|mov|webm)(\?|$)/i)
          blocks.concat Notion::Helpers.video_block(resolved_url, caption, context)
        elsif node['content-type'].to_s.start_with?('audio/') || resolved_url.match?(/\.(mp3|wav|m4a)(\?|$)/i)
          blocks.concat Notion::Helpers.audio_block(resolved_url, caption, context)
        elsif resolved_url.match?(/\.(png|jpe?g|gif|webp)(\?|$)/i) || resolved_url.match?(/(opengraph\.githubassets\.com|avatars\.githubusercontent\.com)/)
          blocks << ::Notion::Helpers.image_block(resolved_url, caption)
          blocks += ::Notion::Helpers.text_blocks("Caption: #{caption}", context) if caption && !caption.empty?
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

        # Detect language from child <code> or attributes
        lang = 'plain text'
        code_el = node.at_css('code') || node
        if (cls = code_el['class']) && cls.match(/language-(\w+)/)
          lang = $1
        elsif (data_lang = code_el['data-lang'])
          lang = data_lang.strip
        end

        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        Helpers.chunk_rich_text(rich_text).map do |chunk|
          {
            object: 'block',
            type: 'code',
            code: { rich_text: chunk, language: lang }
          }
        end
      end

      def self.process_heading_blocks(node, context, level:)
        text = node.text.strip
        return [] if text.empty?
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        Helpers.chunk_rich_text(rich_text).map do |chunk|
          {
            object: 'block',
            type: "heading_#{level}",
            "heading_#{level}".to_sym => { rich_text: chunk }
          }
        end
      end

      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?
        rich_spans = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_spans.empty?
        Helpers.chunk_rich_text(rich_spans).map do |chunk|
          {
            object: 'block',
            type: 'quote',
            quote: { rich_text: chunk }
          }
        end
      end

      def self.inside_bc_attachment?(node)
        node.ancestors.any? { |ancestor| ancestor.name == 'bc-attachment' }
      end

      # ----------------------
      # Table processing
      # ----------------------
      def self.process_table(table_node, context)
        rows = table_node.css('tr')
        return [] if rows.empty?

        blocks = []
        rows.each do |tr|
          cells = tr.css('th, td').map { |c| c.text.strip }.reject(&:empty?)
          next if cells.empty?

          row_text = cells.join(" \t ") # simple tab delimiter
          blocks.concat Notion::Helpers.text_blocks(row_text, context)
        end
        blocks
      end

      # ----------------------
      # Details / summary -> toggle block
      # ----------------------
      def self.process_details_toggle(details_node, context)
        summary_node = details_node.at_css('summary')
        summary_text = summary_node&.text&.strip || 'Details'

        # Remove summary from children when building body blocks
        summary_node&.remove

        body_html = details_node.inner_html.strip
        body_blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(body_html, nil, "DetailsBody #{context}")

        [
          {
            object: 'block',
            type:   'toggle',
            toggle: {
              rich_text: [{ type: 'text', text: { content: summary_text } }],
              children:  (body_blocks + embed_blocks).compact
            }
          }
        ]
      rescue => e
        warn "⚠️ [process_details_toggle] Error: #{e.message} (#{context})"
        []
      end
    end
  end
end
