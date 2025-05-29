# /Users/tom/src/buildkite/basecamp-to-notion/utils/media_extractor/handlers.rb
# frozen_string_literal: true
require_relative './constants'
require_relative './helpers'      # => Utils::MediaExtractor::Helpers
require_relative './logger'
require_relative './resolver'     # => resolve_basecamp_url, basecamp_asset_url? …
require_relative './rich_text'
require 'set'
require 'nokogiri'
require_relative '../../notion/constants'
require_relative '../../notion/uploads' # For Notion::Uploads module

module Utils
  module MediaExtractor
    module Handlers
      extend ::Utils::Logging
      extend ::Utils::MediaExtractor::Helpers
      extend ::Utils::MediaExtractor::Resolver

      # ---------------------------------------------------------------
      unless defined?(@handlers_logged)
        log "✅ [MediaExtractor::Handlers] Image/media extraction handlers loaded and ready"
        @handlers_logged = true
      end

      SKIP_CHILDREN_NODES = ['bc-attachment']

      # ===============================================================
      #  DOM traversal
      # ===============================================================
      def self.handle_node_recursive(node, context, parent_page_id,
                                     notion_blocks, embed_blocks,
                                     seen_nodes = Set.new)
        return if node.comment?
        return if seen_nodes.include?(node.object_id)

        # Skip to allow for nested lists
        if node.name.downcase == 'li' || node.ancestors.any? { |a| a.name == 'li' }
          debug "↪️ [handle_node_recursive] Skipping <li> or child‑of‑li node: <#{node.name}> (#{context})"
          return
        end

        seen_nodes << node.object_id
        debug "[handle_node_recursive] visiting <#{node.name}> (#{context})"

        # Handle wrappers
        case node.name.downcase
        when 'div', 'p'
          notion_blocks.concat process_div_or_paragraph(node, context, parent_page_id)
          return
        when 'ul', 'ol'
          notion_blocks.concat build_nested_list_blocks(node, context, seen_nodes)
          return
        when 'table'
          notion_blocks.concat process_table(node, context)
          return
        when 'details'
          notion_blocks.concat process_details_toggle(node, context)
          return
        end

        handle_node(node, context, parent_page_id, notion_blocks, embed_blocks, seen_nodes)
        return if SKIP_CHILDREN_NODES.include?(node.name)

        node.children.each do |child|
          next unless child.element?
          handle_node_recursive(child, context, parent_page_id,
                                notion_blocks, embed_blocks, seen_nodes)
        end
      end

      def self.handle_node(node, context, parent_page_id, notion_blocks, embed_blocks, seen_nodes = Set.new)
        return if inside_bc_attachment?(node) && node.name != 'bc-attachment'

        case node.name.downcase
        when 'div', 'p', 'ul', 'ol', 'li'
          # handled elsewhere
        when 'br'
          return
        when 'bc-attachment'
          return if node['content-type'] == 'application/vnd.basecamp.mention'
          blocks = process_bc_attachment(node, context, parent_page_id)
          validate_blocks!(blocks, 'process_bc_attachment', node, context)
          notion_blocks.concat(blocks)
        when 'figure'
          blocks = process_figure(node, context, parent_page_id)
          validate_blocks!(blocks, 'process_figure', node, context)
          notion_blocks.concat(blocks)
        when 'figcaption'
          debug "[handle_node] forcibly skipping <figcaption> (#{context})"
        when 'pre'
          blocks = process_code_block(node, context)
          validate_blocks!(blocks, 'process_code_block', node, context)
          notion_blocks.concat(blocks)
        when 'h1'
          notion_blocks.concat process_heading_blocks(node, context, level: 1)
        when 'h2'
          notion_blocks.concat process_heading_blocks(node, context, level: 2)
        when 'h3'
          notion_blocks.concat process_heading_blocks(node, context, level: 3)
        when 'blockquote'
          blocks = process_quote_block(node, context)
          validate_blocks!(blocks, 'process_quote_block', node, context)
          notion_blocks.concat(blocks)
        when 'table'
          notion_blocks.concat process_table(node, context)
        when 'details'
          notion_blocks.concat process_details_toggle(node, context)
        when 'hr'
          notion_blocks << Helpers.divider_block
        when 'iframe'
          embed_blocks << Helpers.build_embed_block(node['src'], context) if node['src']
        else
          debug "[handle_node] Unhandled node type: #{node.name} (#{context})"
        end
      end

      # ===============================================================
      #  Paragraph / DIV
      # ===============================================================
      def self.process_div_or_paragraph(node, context, parent_page_id)
        return [Notion::Helpers.empty_paragraph_block] if empty_or_whitespace_div?(node)

        blocks               = []
        current_inline_group = []
        seen_nodes           = Set.new

        build_paragraph_blocks = lambda do |inline_nodes|
          next if inline_nodes.empty?

          inline_html     = inline_nodes.map(&:to_html).join
          frag            = Nokogiri::HTML::DocumentFragment.parse(inline_html)
          rich_text_spans = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(frag, context)
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
          if child.element? && child.name == 'bc-attachment' &&
             child['content-type'] != 'application/vnd.basecamp.mention'
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat(process_bc_attachment(child, context, parent_page_id))
          elsif child.element? && %w[ul ol].include?(child.name)
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat build_nested_list_blocks(child, context, seen_nodes)
          elsif child.element? && child.name.downcase == 'figure'
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat process_figure(child, context, parent_page_id)
          elsif child.element? && %w[h1 h2 h3].include?(child.name.downcase)
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            level = child.name[1].to_i
            blocks.concat process_heading_blocks(child, context, level:)
          else
            current_inline_group << child
          end
        end
        build_paragraph_blocks.call(current_inline_group)
        blocks.compact
      end

      def self.empty_or_whitespace_div?(node)
        content = node.inner_html.strip
        return true if content.empty? || content.downcase == '<br>'
        return true if content.gsub('&nbsp;', '').strip.empty?
        false
      end

      # ===============================================================
      #  Lists
      # ===============================================================
      def self.build_nested_list_blocks(list_node, context, seen_nodes)
        blocks = []

        list_node.xpath('./li').each do |li_node|
          next if seen_nodes.include?(li_node.object_id)
          seen_nodes << li_node.object_id

          content_nodes = li_node.children.reject { |child| %w[ul ol].include?(child.name) }
          nested_lists  = li_node.children.select { |child| %w[ul ol].include?(child.name) }

          fragment   = Nokogiri::HTML.fragment(content_nodes.map(&:to_html).join)
          rich_text  = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(fragment, context)
          next if rich_text.empty?

          if li_node['data-checked'] || li_node['class'].to_s.downcase.include?('checkbox') ||
             li_node.at_css('input[type="checkbox"]')
            block_type = 'to_do'
            checked    = li_node['data-checked'] == 'true' ||
                         li_node.at_css('input[type="checkbox"][checked]')
          else
            block_type = list_node.name == 'ol' ? 'numbered_list_item' : 'bulleted_list_item'
          end

          block = {
            object: 'block',
            type:   block_type,
            block_type.to_sym => { rich_text: rich_text }
          }
          block[block_type.to_sym][:checked] = checked if block_type == 'to_do'

          nested_blocks = nested_lists.flat_map { |sub| build_nested_list_blocks(sub, context, seen_nodes) }
          if nested_blocks.any?
            if li_node.ancestors.count { |a| a.name == 'li' } >= 2
              log "⚠️ [build_nested_list_blocks] Depth > 3 — promoting children (#{context})"
              blocks.concat(nested_blocks)
            else
              block[block_type.to_sym][:children] = nested_blocks
            end
          end
          blocks << block
        end
        blocks
      end
      # ---------------------------------------------------------------
      #  Attachments / <figure> nodes
      # ---------------------------------------------------------------
      def self._process_bc_attachment_or_figure(node, raw_url, context, parent_page_id)
        return [] if raw_url.nil? || raw_url.empty?

        blocks = []
        caption_node = node.at_css('figcaption')
        caption = caption_node&.text&.strip
        caption_node&.remove # Don’t keep the node around

        # 1️⃣ Resolve the Basecamp link (may still be private)
        resolved_url = Resolver.resolve_basecamp_url(raw_url, context)

        is_notion_hosted_block = false
        uploaded_mime_type = nil
        final_url_for_block = resolved_url # Default, may be overridden or become nil if file_id is used
        file_id_for_block = nil
        filename_from_upload = nil

        # 2️⃣ If Notion uploads are enabled and the asset is still private (or a Google URL that needs proxying),
        #    try to upload it to Notion.
        should_attempt_upload = Notion::Uploads.enabled? &&
                                (Resolver.still_private_asset?(resolved_url) ||
                                 resolved_url.to_s.include?('googleusercontent.com') ||
                                 resolved_url.to_s.include?('usercontent.google.com'))

        if should_attempt_upload
          url_to_upload = resolved_url || raw_url # Ensure we have a URL
          upload_result = nil

          if url_to_upload.to_s.include?('googleusercontent.com') || url_to_upload.to_s.include?('usercontent.google.com')
            log "[Handlers] Attempting Google URL upload for: #{url_to_upload} - Context: #{context}"
            upload_result = Notion::Uploads::FileUpload.upload_from_google_url(url_to_upload, context: context)
          elsif Resolver.still_private_asset?(url_to_upload) # Check again if it's a private Basecamp asset
            log "[Handlers] Attempting Basecamp asset upload for: #{url_to_upload} - Context: #{context}"
            upload_result = Notion::Uploads::FileUpload.upload_from_basecamp_url(url_to_upload, context: context)
          else
            log "[Handlers] URL #{url_to_upload} is not a private Basecamp asset or Google URL, skipping Notion upload attempt. - Context: #{context}"
          end

          if upload_result && upload_result[:success]
            is_notion_hosted_block = true
            uploaded_mime_type     = upload_result[:mime_type]
            file_id_for_block      = upload_result[:file_upload_id]
            filename_from_upload   = upload_result[:filename]

            if upload_result[:notion_url] # Direct URL from multi-part complete
              final_url_for_block = upload_result[:notion_url]
              log "[Handlers] Successfully uploaded to Notion (direct URL): #{final_url_for_block} (MIME: #{uploaded_mime_type}) - Context: #{context}"
            else # Successful upload, will use file_id_for_block for the Notion block
              final_url_for_block = nil # Ensure no external URL is used for the block itself
              log "[Handlers] Successfully uploaded to Notion (will use file_id: #{file_id_for_block}) (MIME: #{uploaded_mime_type}, Filename: #{filename_from_upload}) - Context: #{context}"
            end
          else # Upload not attempted, or failed
            is_notion_hosted_block = false
            file_id_for_block      = nil

            if upload_result # Upload was attempted but failed
              error_msg = upload_result[:error] || "Unknown upload error"
              warn "[Handlers] Notion upload failed for #{url_to_upload}. Error: #{error_msg}. - Context: #{context}"
              if Resolver.still_private_asset?(raw_url)
                final_url_for_block = raw_url
                warn "[Handlers] Falling back to original Basecamp URL: #{final_url_for_block} - Context: #{context}"
              end
            elsif should_attempt_upload
              warn "[Handlers] Notion upload was scheduled for #{url_to_upload} but no upload_result was obtained. Falling back. - Context: #{context}"
              if Resolver.still_private_asset?(raw_url)
                final_url_for_block = raw_url
              end
            end
          end
        end

        # 3️⃣ Decide which kind of Notion block we need
        can_create_notion_block = is_notion_hosted_block || final_url_for_block

        unless can_create_notion_block
          warn "[Handlers] No usable URL or file_id found for raw_url: #{raw_url}, skipping block creation. - Context: #{context}"
          return []
        end

        if is_notion_hosted_block
          notion_block_type_string = if uploaded_mime_type&.start_with?('image/')
                                     'image'
                                   elsif uploaded_mime_type == 'application/pdf'
                                     'pdf'
                                   elsif uploaded_mime_type&.start_with?('video/')
                                     'video'
                                   elsif uploaded_mime_type&.start_with?('audio/')
                                     'audio'
                                   else
                                     'file'
                                   end

          caption_payload_for_media = nil
          actual_caption = caption || filename_from_upload
          if actual_caption && !actual_caption.empty?
            caption_payload_for_media = [{ type: "text", text: { content: actual_caption.strip } }]
          end

          # Determine the key for the block type specific content (e.g., :image, :file, :pdf)
          payload_key = notion_block_type_string.to_sym

          block_data_for_type_key = nil # This will hold the content for the payload_key (e.g., image object, file object)

          if file_id_for_block
            # Primary: Use file_upload_id from Notion upload
            block_data_for_type_key = {
              type: "file_upload", # Indicates the source is a Notion file_upload object
              file_upload: {
                id: file_id_for_block
              }
            }
            log "[Handlers] Constructing Notion block using file_id: #{file_id_for_block} for type '#{notion_block_type_string}'. Context: #{context}"

          elsif final_url_for_block
            # Secondary: Use final_url_for_block (e.g., from multi-part upload or if Notion API provides a direct S3 URL)
            # This assumes final_url_for_block is a Notion S3 URL that can be used directly.
            block_data_for_type_key = {
              url: final_url_for_block
              # For a Notion S3 URL, 'type' is not 'external'. The block type (image, file) implies how to handle the URL.
            }
            log "[Handlers] Constructing Notion block using final_url_for_block for type '#{notion_block_type_string}'. Context: #{context}"

          else
            # Fallback: Neither file_id_for_block nor final_url_for_block is available from upload_result.
            # Attempt to use resolved_url as an external link.
            if resolved_url
              warn "[Handlers] Notion-hosted block expected, but file_id and S3 URL are missing. Raw: #{raw_url}. Falling back to external link: #{resolved_url}. Context: #{context}"
              blocks.concat(::Notion::Helpers.basecamp_asset_fallback_blocks(resolved_url, caption || filename_from_upload || "Linked Asset", context))
              return blocks.compact # Exit processing for this asset, returning blocks formed by fallback
            else
              error "[Handlers] Critical: Cannot create Notion block. All identifiers (file_id, S3 URL, resolved_url) missing for raw_url: #{raw_url}. Skipping. Context: #{context}"
              return [] # No block can be created for this asset
            end
          end

          # If block_data_for_type_key is nil here, it means an early return happened (e.g. from fallback).
          # Otherwise, proceed to add caption and name, then construct the block.

          if block_data_for_type_key
            # Add caption if it exists. caption_payload_for_media was defined earlier.
            block_data_for_type_key[:caption] = caption_payload_for_media if caption_payload_for_media

            # For 'file' type blocks, Notion requires a 'name' property within the file object.
            if notion_block_type_string == 'file'
              file_block_name = filename_from_upload # Prioritize filename from upload result
              if file_block_name.nil? || file_block_name.strip.empty?
                file_block_name = caption # Fallback to original caption text
                if file_block_name.nil? || file_block_name.strip.empty?
                  file_block_name = "Untitled File" # Ultimate fallback
                end
              end
              block_data_for_type_key[:name] = file_block_name.strip
            end

            # Construct the final block structure and add it to the blocks array
            blocks << {
              object: 'block',
              type: notion_block_type_string, # The actual Notion block type: 'image', 'file', 'pdf', etc.
              payload_key => block_data_for_type_key # e.g., image: { type: "file_upload", ... } or file: { url: ..., name: ... }
            }
          else
            # This path should ideally not be reached if early returns are correct.
            # If block_data_for_type_key is nil, it means no block content was formed by the primary/secondary paths,
            # and the fallback path either returned or also failed to produce blocks (which should have returned []).
            # This log is a safeguard.
            log "[Handlers] No block data was constructed for Notion-hosted asset (raw_url: #{raw_url}), and fallback did not result in blocks or early exit. Context: #{context}"
          end

        else # Not a Notion-hosted file, must be an external URL
          if final_url_for_block.nil?
            warn "[Handlers] External URL is nil for raw_url: #{raw_url}, cannot create embed/link. - Context: #{context}"
            return []
          end

          url_for_external_block = resolved_url || final_url_for_block

          if url_for_external_block.nil?
              warn "[Handlers] No URL available for external block. Raw: #{raw_url}. Skipping. - Context: #{context}"
              return []
          end

          is_external_image = Helpers.image_url?(url_for_external_block) || (node['content-type']&.start_with?('image/'))

          if is_external_image
            caption_payload = caption ? [{ type: "text", text: { content: caption } }] : []
            blocks << {
              object: 'block',
              type:   'image',
              image:  {
                type:     'external',
                external: { url: url_for_external_block },
                caption:  caption_payload
              }
            }
          else
            link_text = caption || node['sgid'] || (File.basename(URI.parse(url_for_external_block).path) rescue nil) || "Attached File"
            blocks.concat(::Notion::Helpers.basecamp_asset_fallback_blocks(url_for_external_block, link_text.strip, context))
          end
        end

        blocks.compact
      rescue StandardError => e
        warn "💥 [Handlers._process_bc_attachment_or_figure] Error processing node: #{e.message} - URL: #{raw_url} - Context: #{context}"
        warn e.backtrace.take(5).join("\n")
        if resolved_url || raw_url
          fallback_url = resolved_url || raw_url
          fallback_text = caption || "Error processing attachment - see link"
          blocks.concat(::Notion::Helpers.basecamp_asset_fallback_blocks(fallback_url, fallback_text, context))
          return blocks.compact
        end
        []
      end

      def self.process_bc_attachment(node, context, parent_page_id)
        return process_figure(node, context, parent_page_id) if node.at_css('figure')
        raw_url = (node['href'] || node['url'] || node['src'])&.strip
        _process_bc_attachment_or_figure(node, raw_url, context, parent_page_id)
      end

      def self.process_figure(node, context, parent_page_id)
        img      = node.at_css('img')
        raw_url  = (node['href'] || img&.[]('src'))&.strip
        _process_bc_attachment_or_figure(node, raw_url, context, parent_page_id)
      end

      # ---------------------------------------------------------------
      #  Code, headings, quote, table, details...
      # ---------------------------------------------------------------
      def self.process_code_block(node, context)
        text = node.text.strip
        return [] if text.empty?

        lang = 'plain text'
        code_el = node.at_css('code') || node
        if (cls = code_el['class'])&.match(/language-(\w+)/)
          lang = Regexp.last_match(1)
        elsif (data_lang = code_el['data-lang'])
          lang = data_lang.strip
        end

        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if rich_text.empty?
        Helpers.chunk_rich_text(rich_text).map do |chunk|
          {
            object: 'block',
            type:   'code',
            code:   { rich_text: chunk, language: lang }
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
            type:   "heading_#{level}",
            "heading_#{level}".to_sym => { rich_text: chunk }
          }
        end
      end

      def self.process_quote_block(node, context)
        text = node.text.strip
        return [] if text.empty?
        spans = Utils::MediaExtractor::RichText.extract_rich_text_from_string(text, context)
        return [] if spans.empty?
        Helpers.chunk_rich_text(spans).map do |chunk|
          {
            object: 'block',
            type:   'quote',
            quote:  { rich_text: chunk }
          }
        end
      end

      def self.inside_bc_attachment?(node)
        node.ancestors.any? { |a| a.name == 'bc-attachment' }
      end

      # ---------------------------------------------------------------
      #  Table
      # ---------------------------------------------------------------
      def self.process_table(table_node, context)
        rows = table_node.css('tr')
        return [] if rows.empty?

        blocks = []
        rows.each do |tr|
          cells = tr.css('th, td').map { |c| c.text.strip }.reject(&:empty?)
          next if cells.empty?
          row_text = cells.join(" \t ")
          blocks.concat Notion::Helpers.text_blocks(row_text, context)
        end
        blocks
      end

      # ---------------------------------------------------------------
      #  <details>/<summary> toggle
      # ---------------------------------------------------------------
      def self.process_details_toggle(details_node, context)
        summary_node = details_node.at_css('summary')
        summary_text = summary_node&.text&.strip || 'Details'
        summary_node&.remove

        body_html = details_node.inner_html.strip
        body_blocks, _media, embed_blocks =
          ::Utils::MediaExtractor.extract_and_clean(body_html, nil, "DetailsBody #{context}")

        [{
          object: 'block',
          type:   'toggle',
          toggle: {
            rich_text: [{ type: 'text', text: { content: summary_text } }],
            children:  (body_blocks + embed_blocks).compact
          }
        }]
      rescue => e
        warn "⚠️ [process_details_toggle] Error: #{e.message} (#{context})"
        []
      end

      # ---------------------------------------------------------------
      #  Validation helper
      # ---------------------------------------------------------------
      def self.validate_blocks!(blocks, origin, node, context)
        # Hook for deep JSON‑schema validation if ever required
        # Optional: add JSON structure validation here
        # Uncomment this for deep validation of blocks in case of errors
        # unless blocks.is_a?(Array) && blocks.all? { |b| b.is_a?(Hash) && b[:object] == 'block' }
        #   warn "❌ [#{origin}] produced invalid block(s): #{blocks.inspect}"
        #   warn "🧩 From node: #{node.to_html.strip} (#{context})"
        #   raise "Invalid block from #{origin}"
        # end
      end
    end
  end
end