# notion/helpers.rb

require_relative "./constants"
require_relative "./sanitization"
require_relative "../config"
require_relative "../utils/logging"
require_relative "../utils/media_extractor"

module Notion
  module Helpers
    extend ::Utils::Logging

    def self.text_blocks(text, context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "TextBlocks#{context ? " (#{context})" : ""}"
      )

      total_blocks = blocks.size + embed_blocks.size
      debug "🧩 [text_block] MediaExtractor returned #{total_blocks} blocks (text: #{blocks.size}, embeds: #{embed_blocks.size}) for context: #{context}"
      debug_block_previews(blocks + embed_blocks, context: context, label: 'text_block')

      (blocks + embed_blocks).compact
    end

    def self.heading_blocks(text, level = 2, context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "HeadingBlocks#{context ? " (#{context})" : ""}"
      )

      return [] if blocks.compact.empty?

      if blocks.size > 1
        warn "⚠️ [heading_blocks] Multiple blocks detected (#{blocks.size}) — expected single rich_text block. Context: #{context}"
      end

      first_block = blocks.shift
      rich_text   = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [heading_blocks] Building heading level #{level} block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "heading_blocks rich_text")

      [{
        object: "block",
        type:   "heading_#{level}",
        "heading_#{level}": { rich_text: rich_text }
      }] + embed_blocks.compact
    end

    def self.callout_blocks(text, emoji = "💬", context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "CalloutBlocks#{context ? " (#{context})" : ""}"
      )

      return [] if blocks.compact.empty?

      if blocks.size > 1
        warn "⚠️ [callout_block] Multiple blocks detected (#{blocks.size}) — expected single rich_text block. Context: #{context}"
      end

      first_block = blocks.shift
      rich_text   = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [callout_blocks] Building callout block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "callout_blocks rich_text")

      [{
        object: "block",
        type:   "callout",
        callout: {
          icon:      { type: "emoji", emoji: emoji },
          rich_text: rich_text
        }
      }] + embed_blocks.compact
    end

    def self.label_and_link_block(label, url, context = nil)
      return [] unless url && !url.strip.empty?

      debug "🧩 [label_and_link_block] Building label and link block for: #{label} #{url} (#{context})"

      # Use Notion::Sanitization.valid_notion_url? to check link validity
      link_valid = Notion::Sanitization.valid_notion_url?(url)
      link_part = if link_valid
        { type: "text", text: { content: url.to_s.strip, link: { url: url.to_s.strip } } }
      else
        { type: "text", text: { content: url.to_s.strip } } # plain text if invalid
      end

      {
        object:    "block",
        type:      "paragraph",
        paragraph: {
          rich_text: [
            { type: "text", text: { content: "#{label.to_s.strip} " } },
            link_part
          ]
        }
      }
    end

    MAX_NOTION_URL_LEN = 2000

    def self.image_block(url, caption_input = nil, context = nil)
      return [] unless url && !url.strip.empty?
      cleaned_url = url.to_s.strip # Ensure it's a string and stripped

      if cleaned_url.length >= MAX_NOTION_URL_LEN
        warn "⚠️ [image_block] URL length #{cleaned_url.length} exceeds Notion limit (#{MAX_NOTION_URL_LEN}) — using fallback (#{context})"
        # Determine a string caption for the fallback
        fallback_caption_text = 'Image'
        if caption_input.is_a?(Array) && caption_input.first&.dig(:text, :content)
          fallback_caption_text = caption_input.first[:text][:content]
        elsif caption_input.is_a?(String)
          fallback_caption_text = caption_input
        end
        return basecamp_asset_fallback_blocks(cleaned_url, fallback_caption_text, context)
      end

      payload = { type: "external", external: { url: cleaned_url } }
      if caption_input
        if caption_input.is_a?(Array) && caption_input.all? { |item| item.is_a?(Hash) }
          payload[:caption] = caption_input unless caption_input.empty?
        elsif caption_input.is_a?(String) && !caption_input.strip.empty?
          payload[:caption] = [{ type: "text", text: { content: caption_input.strip } }]
        end
      end

      block = { object: "block", type: "image", image: payload }
      [block].tap { |b_arr| debug "[image_block] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.pdf_file_block(url, caption_input = nil, context = nil)
      return [] unless url && !url.strip.empty?
      cleaned_url = url.to_s.strip

      if cleaned_url.length >= MAX_NOTION_URL_LEN
        warn "⚠️ [pdf_file_block] URL length #{cleaned_url.length} exceeds Notion limit (#{MAX_NOTION_URL_LEN}) — using fallback (#{context})"
        fallback_caption_text = 'PDF Document'
        if caption_input.is_a?(Array) && caption_input.first&.dig(:text, :content)
          fallback_caption_text = caption_input.first[:text][:content]
        elsif caption_input.is_a?(String)
          fallback_caption_text = caption_input
        end
        return basecamp_asset_fallback_blocks(cleaned_url, fallback_caption_text, context)
      end

      payload = { type: "external", external: { url: cleaned_url } }
      if caption_input
        if caption_input.is_a?(Array) && caption_input.all? { |item| item.is_a?(Hash) }
          payload[:caption] = caption_input unless caption_input.empty?
        elsif caption_input.is_a?(String) && !caption_input.strip.empty?
          payload[:caption] = [{ type: "text", text: { content: caption_input.strip } }]
        end
      end

      block = { object: "block", type: "pdf", pdf: payload }
      [block].tap { |b_arr| debug "[pdf_file_block] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.audio_block(url, caption_input = nil, context = nil)
      return [] unless url && !url.strip.empty?
      cleaned_url = url.to_s.strip

      if cleaned_url.length >= MAX_NOTION_URL_LEN # Added URL length check for consistency
        warn "⚠️ [audio_block] URL length #{cleaned_url.length} exceeds Notion limit (#{MAX_NOTION_URL_LEN}) — using fallback (#{context})"
        fallback_caption_text = 'Audio File'
        if caption_input.is_a?(Array) && caption_input.first&.dig(:text, :content)
          fallback_caption_text = caption_input.first[:text][:content]
        elsif caption_input.is_a?(String)
          fallback_caption_text = caption_input
        end
        return basecamp_asset_fallback_blocks(cleaned_url, fallback_caption_text, context)
      end

      payload = { type: "external", external: { url: cleaned_url } }
      if caption_input
        if caption_input.is_a?(Array) && caption_input.all? { |item| item.is_a?(Hash) }
          payload[:caption] = caption_input unless caption_input.empty?
        elsif caption_input.is_a?(String) && !caption_input.strip.empty?
          payload[:caption] = [{ type: "text", text: { content: caption_input.strip } }]
        end
      end

      block = { object: "block", type: "audio", audio: payload }
      [block].tap { |b_arr| debug "[audio_block] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.video_block(url, caption_input = nil, context = nil)
      return [] unless url && !url.strip.empty?
      cleaned_url = url.to_s.strip

      if cleaned_url.length >= MAX_NOTION_URL_LEN
        warn "⚠️ [video_block] URL length #{cleaned_url.length} exceeds Notion limit (#{MAX_NOTION_URL_LEN}) — using fallback (#{context})"
        fallback_caption_text = 'Video File'
        if caption_input.is_a?(Array) && caption_input.first&.dig(:text, :content)
          fallback_caption_text = caption_input.first[:text][:content]
        elsif caption_input.is_a?(String)
          fallback_caption_text = caption_input
        end
        return basecamp_asset_fallback_blocks(cleaned_url, fallback_caption_text, context)
      end

      payload = { type: "external", external: { url: cleaned_url } }
      if caption_input
        if caption_input.is_a?(Array) && caption_input.all? { |item| item.is_a?(Hash) }
          payload[:caption] = caption_input unless caption_input.empty?
        elsif caption_input.is_a?(String) && !caption_input.strip.empty?
          payload[:caption] = [{ type: "text", text: { content: caption_input.strip } }]
        end
      end

      block = { object: "block", type: "video", video: payload }
      [block].tap { |b_arr| debug "[video_block] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.embed_block(url, caption = nil, context = nil)
      return [] unless url && !url.strip.empty?

      payload = { url: url }
      if caption && !caption.strip.empty?
        payload[:caption] = [{ type: "text", text: { content: caption } }]
      end

      block = { object: "block", type: "embed", embed: payload }
      [block].tap { |b_arr| debug "[embed_block] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.file_block_external(url, name, caption_input = nil, context = nil)
      return [] unless url && !url.strip.empty?

      if url.length >= MAX_NOTION_URL_LEN
        warn "⚠️ [file_block_external] URL length #{url.length} exceeds Notion limit (#{MAX_NOTION_URL_LEN}) — using fallback (#{context})"
        # Determine a string caption for the fallback
        fallback_caption_text = name || 'File'
        if caption_input.is_a?(Array) && caption_input.first&.dig(:text, :content)
          fallback_caption_text = caption_input.first[:text][:content] # Try to get a string from rich text
        elsif caption_input.is_a?(String)
          fallback_caption_text = caption_input
        end
        return basecamp_asset_fallback_blocks(url, fallback_caption_text, context)
      end

      payload = { type: "external", external: { url: url } }
      payload[:name] = name if name && !name.strip.empty?

      if caption_input
        if caption_input.is_a?(Array) && caption_input.all? { |item| item.is_a?(Hash) }
          payload[:caption] = caption_input unless caption_input.empty?
        elsif caption_input.is_a?(String) && !caption_input.strip.empty?
          payload[:caption] = [{ type: "text", text: { content: caption_input.strip } }]
        end
      end

      block = { object: "block", type: "file", file: payload }
      [block].tap { |b_arr| debug "[file_block_external] => #{b_arr.first.inspect} (#{context})" unless b_arr.empty? }
    end

    def self.empty_paragraph_block
      {
        object:    "block",
        type:      "paragraph",
        paragraph: { rich_text: [{ type: "text", text: { content: " " } }] }
      }
    end

    def self.divider_block
      debug "🧩 [divider_block] Creating divider block"
      { object: "block", type: "divider", divider: {} }
    end

    def self.comment_section_blocks(comment_blocks, context = nil)
      compacted = deep_compact_blocks(comment_blocks)
      return [] if compacted.empty?

      debug "🗨️ [comment_section_blocks] Building comment section with #{compacted.size} blocks (#{context})"
      [
        divider_block,
        *heading_blocks("🗨️ Comments:", 2, context),
        *compacted,
        divider_block
      ].compact
    end

    def self.comment_author_block(author_name, created_at, context = nil)
      debug "🧩 [comment_author_block] Building comment author block for #{author_name} at #{created_at} (#{context})"
      callout_blocks("👤 #{author_name} · 🕗 #{created_at}", "💬", context).compact
    end

    def self.wrap_in_callout(blocks, text = "Additional context", emoji = "💬")
      compacted = deep_compact_blocks(blocks)
      return compacted if compacted.empty?

      debug "🧩 [wrap_in_callout] Wrapping #{compacted.size} blocks in callout"
      [{
        object: "block",
        type:   "callout",
        callout: {
          icon:      { type: "emoji", emoji: emoji },
          rich_text: [{ type: "text", text: { content: text } }]
        }
      }] + compacted
    end

    def self.basecamp_asset_fallback_blocks(url, caption, context)
      debug "📎 [basecamp_asset_fallback_blocks] Creating fallback callout for #{url} (#{context})"

      cleaned = url.to_s.strip
      uri     = URI.parse(cleaned) rescue nil
      link    = uri&.scheme&.match?(/^https?$/) ? { url: cleaned } : nil
      return [] unless link

      rich_text = [{ type: 'text', text: { content: 'Basecamp asset', link: link } }]
      rich_text << { type: 'text', text: { content: " – #{caption}" } } if caption&.strip&.length&.positive?

      [{
        object:  'block',
        type:    'callout',
        callout: {
          icon:      { type: 'emoji', emoji: '🔗' },
          rich_text: rich_text,
          color:     'yellow_background'
        }
      }]
    end

    def self.debug_block_previews(blocks, context:, label:)
      return if blocks.empty?
      debug "🧩 [#{label}] Previewing first #{[blocks.size, 5].min} blocks (#{context})"
      blocks.first(5).each_with_index do |block, idx|
        debug "    [#{label} block #{idx}] #{block.to_json[0..500]}"
      end
    end

    def self.debug_rich_text_preview(rich_text_array, context:, label:)
      return if rich_text_array.empty?
      debug "🧩 [#{label}] RichText preview (#{context}): total #{rich_text_array.size} items"
      rich_text_array.each_with_index do |text, idx|
        preview = text.dig(:text, :content).to_s[0..60]
        debug "    [#{label} item #{idx}] Content preview: '#{preview}'"
      end
    end

    def self.deep_compact_blocks(blocks)
      (blocks || []).compact.reject { |b| b.nil? || b == {} }
    end

    # ----------------------
    # Project Metadata Toggle Block
    # ----------------------
    # Builds a toggle block with project metadata (link, access count, additional fields)
    def self.project_metadata_toggle_block(project_url:, people_count:, additional_info: {})
      # Link to project
      link_block = label_and_link_block("🔗 Project Link", project_url, "metadata")

      # People count paragraph
      count_block = {
        object:    "block",
        type:      "paragraph",
        paragraph: {
          rich_text: [
            { type: "text", text: { content: "👥 People with access: #{people_count}" } }
          ]
        }
      }

      # Additional info blocks
      info_blocks = additional_info.map do |label, value|
        {
          object:    "block",
          type:      "paragraph",
          paragraph: {
            rich_text: [
              { type: "text", text: { content: "#{label}: #{value}" } }
            ]
          }
        }
      end

      all_child_elements = [link_block, count_block, *info_blocks]
      children = all_child_elements.flatten(1).compact

      {
        object: "block",
        type:   "toggle",
        toggle: {
          rich_text: [
            { type: "text", text: { content: "🔍 Project metadata" } }
          ],
          children: children,
          color: "blue_background"
        },
      }
    end
  end
end
