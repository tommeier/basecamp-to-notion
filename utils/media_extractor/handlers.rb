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
                                     notion_blocks, embed_blocks, failed_attachments_details,
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
          notion_blocks.concat process_div_or_paragraph(node, context, parent_page_id, failed_attachments_details)
          return
        when 'ul', 'ol'
          notion_blocks.concat build_nested_list_blocks(node, context, seen_nodes)
          return
        when 'table'
          notion_blocks.concat process_table(node, context)
          return
        when 'details'
          notion_blocks.concat process_details_toggle(node, context, failed_attachments_details)
          return
        end

        handle_node(node, context, parent_page_id, notion_blocks, embed_blocks, failed_attachments_details, seen_nodes)
        return if SKIP_CHILDREN_NODES.include?(node.name)

        node.children.each do |child|
          next unless child.element?
          handle_node_recursive(child, context, parent_page_id,
                                notion_blocks, embed_blocks, failed_attachments_details, seen_nodes)
        end
      end

      def self.handle_node(node, context, parent_page_id, notion_blocks, embed_blocks, failed_attachments_details, seen_nodes = Set.new)
        return if inside_bc_attachment?(node) && node.name != 'bc-attachment'

        case node.name.downcase
        when 'div', 'p', 'ul', 'ol', 'li'
          # handled elsewhere
        when 'br'
          return
        when 'bc-attachment'
          return if node['content-type'] == 'application/vnd.basecamp.mention'
          blocks = process_bc_attachment(node, context, parent_page_id, failed_attachments_details)
          validate_blocks!(blocks, 'process_bc_attachment', node, context)
          notion_blocks.concat(blocks)
        when 'figure'
          blocks = process_figure(node, context, parent_page_id, failed_attachments_details)
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
          notion_blocks.concat process_details_toggle(node, context, failed_attachments_details)
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
      def self.process_div_or_paragraph(node, context, parent_page_id, failed_attachments_details)
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
            blocks.concat(process_bc_attachment(child, context, parent_page_id, failed_attachments_details))
          elsif child.element? && %w[ul ol].include?(child.name)
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat build_nested_list_blocks(child, context, seen_nodes)
          elsif child.element? && child.name.downcase == 'figure'
            build_paragraph_blocks.call(current_inline_group)
            current_inline_group = []
            blocks.concat process_figure(child, context, parent_page_id, failed_attachments_details)
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
        end # Closes list_node.xpath('./li').each do
        blocks # Return value for build_nested_list_blocks
      end # Closes def self.build_nested_list_blocks

      # Note: This method is not currently called from within MediaExtractor::Handlers.
      # It's preserved from a previous version.
      def self.process_list_item(node, context)
        blocks = []
        # Iterate through child_node of the list item (e.g., <span>, <a>, or nested <ul>/<ol>)
        node.children.each_with_index do |child_node, index|
          if child_node.name == 'div' && child_node.css('ul, ol').any?
            # If the div contains a list, process that list.
            child_node.css('ul, ol').each do |nested_list_node|
              # Pass a new Set for seen_nodes to avoid interference if called recursively
              # within a broader seen_nodes context.
              blocks.concat build_nested_list_blocks(nested_list_node, "#{context}_li_div_nested_list_#{index}", Set.new)
            end
          elsif child_node.name == 'ul' || child_node.name == 'ol'
            # If the child is a list itself, process it.
            blocks.concat build_nested_list_blocks(child_node, "#{context}_li_direct_nested_list_#{index}", Set.new)
          else
            # Otherwise, treat as rich text content for the current list item.
            # Create a temporary parent for the child_node to pass to extract_rich_text_from_node_children
            temp_parent = Nokogiri::HTML.fragment("<div></div>").first_element_child
            temp_parent.add_child(child_node.dup) # Use dup to avoid issues with node removal or modification
            rich_text_content = Utils::MediaExtractor::RichText.extract_rich_text_from_node_children(temp_parent, context)

            if rich_text_content.any?
              # This list item contributes a paragraph block with its rich text.
              # This assumes that list items are effectively paragraphs for complex content.
              block = {
                object: 'block',
                type: 'paragraph',
                paragraph: { rich_text: rich_text_content }
              }
              blocks << block
            end
          end # Closes if/elsif/else for child_node in process_list_item
        end # Closes node.children.each_with_index in process_list_item
        blocks # Return value for process_list_item
      end # Closes def self.process_list_item

      # ---------------------------------------------------------------
      #  Attachments / <figure> nodes
      # ---------------------------------------------------------------
      def self._process_bc_attachment_or_figure(node, raw_url, context, parent_page_id, failed_attachments_details)
        return [] if raw_url.nil? || raw_url.empty?

        blocks = []
        caption_node = node.at_css('figcaption')
        caption = caption_node&.text&.strip
        caption_node&.remove # Don’t keep the node around

        # 1️⃣ Resolve the Basecamp link
        resolved_url = nil
        begin
          resolved_url = ::Utils::MediaExtractor::Resolver.resolve_basecamp_url(raw_url, context)
        rescue StandardError => e
          log "🔥 Error resolving URL '#{raw_url}' in _process_bc_attachment_or_figure: #{e.class} - #{e.message} - Backtrace: #{e.backtrace.take(3).join(' | ')}"
          failed_attachments_details << { url: raw_url, error: "#{e.class}: #{e.message}", context: context }
          return [::Notion::Helpers.basecamp_asset_fallback_blocks(raw_url, "Resolution Error: #{e.message}", context)].compact
        end

        if resolved_url.nil?
          log "⚠️ URL '#{raw_url}' resolved to nil after attempt. Using fallback. Context: #{context}"
          failed_attachments_details << { url: raw_url, error: "Resolved to nil", context: context }
          return [::Notion::Helpers.basecamp_asset_fallback_blocks(raw_url, "Failed to resolve after attempt", context)].compact
        end

        is_notion_hosted_block = false
        uploaded_mime_type = nil
        final_url_for_block = resolved_url
        file_id_for_block = nil
        filename_from_upload = nil

        # 2️⃣ If Notion uploads are enabled and the asset might need it
        should_attempt_upload = Notion::Uploads.enabled? &&
                                (::Utils::MediaExtractor::Resolver.still_private_asset?(resolved_url) ||
                                 resolved_url.to_s.include?('googleusercontent.com') ||
                                 resolved_url.to_s.include?('usercontent.google.com'))

        if should_attempt_upload
          url_to_upload = resolved_url
          upload_result = nil
          if url_to_upload.to_s.include?('googleusercontent.com') || url_to_upload.to_s.include?('usercontent.google.com')
            upload_result = Notion::Uploads::FileUpload.upload_from_google_url(url_to_upload, context: context)
          elsif ::Utils::MediaExtractor::Resolver.still_private_asset?(url_to_upload)
            upload_result = Notion::Uploads::FileUpload.upload_from_basecamp_url(url_to_upload, context: context)
          end

          if upload_result && upload_result[:success]
            is_notion_hosted_block = true
            uploaded_mime_type = upload_result[:mime_type]
            file_id_for_block = upload_result[:file_upload_id]
            filename_from_upload = upload_result[:filename]
            final_url_for_block = upload_result[:notion_url] # This might be nil, if so, block uses file_id
            log "[Handlers] Uploaded to Notion (FileID: #{file_id_for_block}, S3: #{final_url_for_block || 'N/A'}, MIME: #{uploaded_mime_type}) - Context: #{context}"
          else
            is_notion_hosted_block = false
            if upload_result # Attempted but failed
              warn "[Handlers] Notion upload failed for #{url_to_upload}. Error: #{upload_result[:error]}. Falling back to resolved_url. - Context: #{context}"
            end
            # final_url_for_block remains 'resolved_url'
          end
        end

        # 3️⃣ Decide which kind of Notion block we need
        actual_caption_text = filename_from_upload || caption
        caption_payload = []
        if actual_caption_text && !actual_caption_text.strip.empty?
          caption_payload = [{ type: "text", text: { content: actual_caption_text.strip } }]
        end

        if is_notion_hosted_block && file_id_for_block
          type_str = if uploaded_mime_type&.start_with?('image/') then 'image'
                     elsif uploaded_mime_type == 'application/pdf' then 'pdf'
                     elsif uploaded_mime_type&.start_with?('video/') then 'video'
                     elsif uploaded_mime_type&.start_with?('audio/') then 'audio'
                     else 'file' end
          payload_key = type_str.to_sym
          payload_content = { type: "file_upload", file_upload: { id: file_id_for_block } }
          payload_content[:caption] = caption_payload if type_str == 'image' && caption_payload.any?
          if type_str == 'file'
            fname = filename_from_upload || caption || (::URI.parse(raw_url).path.split('/').last rescue "Attached File")
            payload_content[:name] = fname.strip
          end
          blocks << { object: 'block', type: type_str, payload_key => payload_content }

        elsif final_url_for_block # Use external URL (publicly resolved_url or Notion S3 from upload)
          content_type = node['content-type']
          if Helpers.image_url?(final_url_for_block) || content_type&.start_with?('image/')
            blocks << ::Notion::Helpers.image_block(final_url_for_block, caption_payload, context)
          elsif Helpers.pdf_url?(final_url_for_block) || content_type == 'application/pdf'
            blocks << ::Notion::Helpers.pdf_file_block(final_url_for_block, caption_payload, context)
          elsif Helpers.video_url?(final_url_for_block) || content_type&.start_with?('video/')
            blocks << ::Notion::Helpers.video_block(final_url_for_block, caption_payload, context)
          elsif Helpers.audio_url?(final_url_for_block) || content_type&.start_with?('audio/')
            blocks << ::Notion::Helpers.audio_block(final_url_for_block, caption_payload, context)
          else # Default to a general file block or embed if possible
            embed = Helpers.build_embed_block(final_url_for_block, context)
            if embed && embed[:embed] && embed[:embed][:url]
              blocks << embed
            else
              fname = filename_from_upload || caption || (::URI.parse(final_url_for_block).path.split('/').last rescue "Linked File")
              blocks << ::Notion::Helpers.file_block_external(final_url_for_block, fname.strip, caption_payload, context)
            end
          end
        else
          # This case means resolved_url was valid, but upload wasn't attempted or failed, AND final_url_for_block became nil (should not happen if logic is sound)
          log "‼️ [Handlers] No usable URL/file_id for block construction. Raw: #{raw_url}. Resolved: #{resolved_url}. Context: #{context}"
          failed_attachments_details << { url: raw_url, error: "No usable URL/file_id after processing", context: context }
          blocks.concat(::Notion::Helpers.basecamp_asset_fallback_blocks(raw_url, caption || "Asset processing failed", context))
        end

        blocks.compact

      rescue StandardError => e
        warn "💥 [Handlers._process_bc_attachment_or_figure] Error: #{e.class} - #{e.message} - URL: #{raw_url} - Context: #{context}"
        warn e.backtrace.first(5).join("\n")
        failed_attachments_details << { url: raw_url, error: "Generic error in _PBAOF: #{e.class}: #{e.message}", context: context }
        # Return a fallback block so the sync process can continue for other elements
        return [::Notion::Helpers.basecamp_asset_fallback_blocks(raw_url || "unknown_url", caption || "Error processing asset", context)].compact
      end

      def self.process_bc_attachment(node, context, parent_page_id, failed_attachments_details)
        # If bc-attachment contains a figure, delegate to process_figure
        # This handles cases where Basecamp might wrap figures in bc-attachment tags
        figure_node = node.at_css('figure')
        if figure_node
          return process_figure(figure_node, context, parent_page_id, failed_attachments_details)
        end

        raw_url = (node['href'] || node['url'] || node['sgid'])&.strip # sgid for direct uploads
        _process_bc_attachment_or_figure(node, raw_url, context, parent_page_id, failed_attachments_details)
      end

      def self.process_figure(node, context, parent_page_id, failed_attachments_details)
        img = node.at_css('img')
        # For figures, the primary URL source is often an <img> tag's src or a link wrapping the figure.
        # Basecamp might also use 'data-image-src' or similar for lazily-loaded images within figures.
        raw_url = (node['href'] || img&.[]('src') || img&.[]('data-src') || node['data-image-src'])&.strip
        _process_bc_attachment_or_figure(node, raw_url, context, parent_page_id, failed_attachments_details)
      end

      # ---------------------------------------------------------------
      #  Code, headings, quote, table, details...
      # ---------------------------------------------------------------
      def self.process_code_block(node, context)
        text = node.text # Keep original spacing for code blocks
        return [] if text.empty? && node.children.empty? # Allow empty code blocks if they are truly empty, not just whitespace

        lang = 'plain text'
        code_el = node.at_css('code') || node # Prefer <code> if present

        # Try to determine language from class or data-lang attribute
        if (cls = code_el['class'])&.match(/language-(\w+)/)
          lang = Regexp.last_match(1)
        elsif (data_lang = code_el['data-lang'])
          lang = data_lang.strip
        end

        # Extract rich text, preserving newlines and essential whitespace for code
        rich_text_spans = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(code_el, context)
        return [] if rich_text_spans.empty?

        # Notion API has a limit on rich text items per block and total length.
        # Chunking is handled by Helpers.chunk_rich_text_for_code_block
        Helpers.chunk_rich_text(rich_text_spans).map do |chunk|
          { object: 'block', type: 'code', code: { rich_text: chunk, language: lang } }
        end
      end

      def self.process_heading_blocks(node, context, level:)
        text = node.text.strip
        return [] if text.empty?
        rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(node, context)
        return [] if rich_text.empty?

        # Notion API has a limit of 2000 characters for heading rich_text content.
        # Chunking is handled by Helpers.chunk_rich_text_for_heading
        Helpers.chunk_rich_text(rich_text).map do |chunk|
          { object: 'block', type: "heading_#{level}", "heading_#{level}".to_sym => { rich_text: chunk } }
        end
      end

      def self.process_quote_block(node, context)
        # For quotes, we want to preserve the structure including newlines within the blockquote.
        # extract_rich_text_from_node should handle this by creating separate text objects for lines.
        rich_text_spans = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(node, context)
        return [] if rich_text_spans.empty?

        # Notion API has a limit on rich text items per block and total length.
        # Chunking is handled by Helpers.chunk_rich_text_for_paragraph_like
        Helpers.chunk_rich_text(rich_text_spans).map do |chunk|
          { object: 'block', type: 'quote', quote: { rich_text: chunk } }
        end
      end

      def self.inside_bc_attachment?(node)
        # Helper to check if a node is a descendant of a bc-attachment tag
        # This is to avoid processing children of bc-attachment if they are handled by process_bc_attachment itself.
        node.ancestors.any? { |ancestor| ancestor.name == 'bc-attachment' }
      end

      # ---------------------------------------------------------------
      #  Table
      # ---------------------------------------------------------------
      def self.process_table(table_node, context)
        # Basic table to paragraph conversion. Notion's table API is complex.
        # This creates a paragraph for each row, with cells tab-separated.
        # A more advanced conversion could create actual Notion tables if needed.
        table_rows_data = []
        has_header = !table_node.css('thead th').empty?

        table_node.css('tr').each_with_index do |tr, row_index|
          row_cells = []
          tr.css('th, td').each do |cell_node|
            # Extract rich text from each cell to preserve formatting
            cell_rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_node(cell_node, "#{context}_table_cell_r#{row_index}")
            row_cells << cell_rich_text
          end
          table_rows_data << { cells: row_cells, is_header_row: (has_header && row_index == 0) }
        end

        return [] if table_rows_data.empty?

        # For simplicity, convert to paragraphs or a code block representation for now.
        # True Notion tables require a different structure.
        # Let's try to format it as a series of paragraphs or a single code block.
        content_for_code_block = table_rows_data.map do |row_data|
          row_data[:cells].map do |cell_rt_array|
            cell_rt_array.map { |rt| rt[:text][:content] }.join
          end.join(" \t|\t ") # Join cells with a tab-pipe-tab separator
        end.join("\n") # Join rows with newline

        return [] if content_for_code_block.strip.empty?

        # Create a code block for the table content
        [{
          object: 'block',
          type: 'code',
          code: {
            rich_text: [{ type: 'text', text: { content: content_for_code_block } }],
            language: 'text' # or 'tsv' or a custom identifier
          }
        }]
      end

      # ---------------------------------------------------------------
      #  <details>/<summary> toggle
      # ---------------------------------------------------------------
      def self.process_details_toggle(details_node, context, failed_attachments_details)
        summary_node = details_node.at_css('summary')
        summary_text = summary_node&.text&.strip || 'Details' # Default summary if empty
        summary_node&.remove # Remove summary from body to avoid duplication in children

        # Process the content inside the <details> tag
        body_html = details_node.inner_html.strip
        body_blocks, _media_files, embed_blocks, failed_toggle_attachments =
          ::Utils::MediaExtractor.extract_and_clean(body_html, nil, "DetailsToggleBody_#{context}")

        # Propagate any failures from inside the toggle up to the main failed_attachments_details array
        failed_attachments_details.concat(failed_toggle_attachments) if failed_attachments_details && failed_toggle_attachments.any?

        # Create rich text for summary
        summary_rich_text = Utils::MediaExtractor::RichText.extract_rich_text_from_string(summary_text, context)
        return [] if summary_rich_text.empty? && body_blocks.empty? && embed_blocks.empty?

        # Ensure summary_rich_text is not empty for the toggle block
        summary_rich_text = [{type: 'text', text: {content: 'Details'}}] if summary_rich_text.empty?

        # Chunk summary rich text if it's too long for Notion's toggle summary limit
        chunked_summary_rich_text = Helpers.chunk_rich_text(summary_rich_text).first || [{type: 'text', text: {content: 'Details'}}]

        toggle_children = (body_blocks + embed_blocks).compact

        [{
          object: 'block',
          type: 'toggle',
          toggle: {
            rich_text: chunked_summary_rich_text,
            children: toggle_children.empty? ? nil : toggle_children # Notion API expects null or non-empty array for children
          }
        }]
      rescue StandardError => e
        warn "⚠️ [process_details_toggle] Error processing <details>: #{e.message} (#{context}) - Backtrace: #{e.backtrace.take(3).join(' | ')}"
        # Fallback: return the summary as a paragraph and the content as best as possible, or a simple error message
        fallback_blocks = []
        fallback_blocks.concat(Utils::MediaExtractor::RichText.extract_rich_text_from_string("Error processing toggle: #{summary_text}", context).map do |chunk|
          { object: 'block', type: 'paragraph', paragraph: { rich_text: chunk } }
        end)
        # Optionally, try to dump details_node.inner_html as a code block if toggle processing fails catastrophically
        # For now, just log the error and return the summary as a paragraph.
        fallback_blocks
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

    end # Closes module Handlers
  end # Closes module MediaExtractor
end # Closes module Utils