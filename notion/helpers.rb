# notion/helpers.rb

require_relative "./constants"
require_relative "./sanitization"
require_relative "../config"
require_relative "../utils/logging"
require_relative "../utils/media_extractor"

module Notion
  module Helpers
    extend ::Utils::Logging

    # ✅ General text block helper
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

    # ✅ Heading block helper
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
      rich_text = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [heading_blocks] Building heading level #{level} block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "heading_blocks rich_text")

      [{
        object: "block",
        type: "heading_#{level}",
        "heading_#{level}": { rich_text: rich_text }
      }] + embed_blocks.compact
    end

    # ✅ Callout block helper
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
      rich_text = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [callout_blocks] Building callout block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "callout_blocks rich_text")

      [{
        object: "block",
        type: "callout",
        callout: {
          icon: { type: "emoji", emoji: emoji },
          rich_text: rich_text
        }
      }] + embed_blocks.compact
    end

    def self.label_and_link_block(label, url, context = nil)
      return [] unless url && !url.strip.empty?

      debug "🧩 [label_and_link_block] Building label and link block for: #{label} #{url} (#{context})"

      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [
            { type: "text", text: { content: "#{label.to_s.strip} " } },
            { type: "text", text: { content: url.to_s.strip, link: { url: url.to_s.strip } } }
          ]
        }
      }
    end

    def self.image_block(url, context)
      return [] unless url && !url.strip.empty?

      {
        object: 'block',
        type: 'image',
        image: {
          type: 'external',
          external: { url: url }
        }
      }.tap { |block| debug "[image_block] => #{block.inspect} (#{context})" }
    end

    def self.pdf_file_block(url, context)
      return [] unless url && !url.strip.empty?

      {
        object: 'block',
        type: 'file',
        file: {
          type: 'external',
          external: { url: url }
        }
      }.tap { |block| debug "[pdf_file_block] => #{block.inspect} (#{context})" }
    end

    def self.empty_paragraph_block
      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [{ type: "text", text: { content: " " } }]
        }
      }
    end

    def self.divider_block
      debug "🧩 [divider_block] Creating divider block"
      { object: "block", type: "divider", divider: {} }
    end

    def self.index_link_block(page_id, title, emoji)
      return [] unless page_id

      debug "🧩 [index_link_block] Creating index link block for page: #{title}"

      {
        object: "block",
        type: "paragraph",
        paragraph: {
          rich_text: [
            { type: "emoji", emoji: emoji },
            { type: "text", text: { content: " " } },
            { type: "mention", mention: { page: { id: page_id } } },
            { type: "text", text: { content: " – #{title}" } }
          ].compact
        }
      }
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
        type: "callout",
        callout: {
          icon: { type: "emoji", emoji: emoji },
          rich_text: [{ type: "text", text: { content: text } }]
        }
      }] + compacted
    end

    def self.basecamp_asset_fallback_blocks(url, caption, context)
      debug "📎 [basecamp_asset_fallback_blocks] Creating fallback callout for #{url} (#{context})"

      cleaned = url.to_s.strip
      uri = URI.parse(cleaned) rescue nil
      link = uri&.scheme&.match?(/^https?$/) ? { url: cleaned } : nil
      return [] unless link

      rich_text = [{ type: 'text', text: { content: 'Basecamp asset', link: link } }]
      rich_text << { type: 'text', text: { content: " – #{caption}" } } if caption&.strip&.length&.positive?

      [{
        object: 'block',
        type: 'callout',
        callout: {
          icon: { type: 'emoji', emoji: '🔗' },
          rich_text: rich_text,
          color: 'yellow_background'
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
  end
end
