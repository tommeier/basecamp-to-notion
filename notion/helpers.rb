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
    def self.text_block(text, context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "TextBlock#{context ? " (#{context})" : ""}"
      )

      total_blocks = blocks.size + embed_blocks.size
      debug "🧩 [text_block] MediaExtractor returned #{total_blocks} blocks (text: #{blocks.size}, embeds: #{embed_blocks.size}) for context: #{context}"
      debug_block_previews(blocks + embed_blocks, context: context, label: 'text_block')

      (blocks + embed_blocks).compact
    end

    # ✅ Heading block helper
    def self.heading_block(text, level = 2, context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "HeadingBlock#{context ? " (#{context})" : ""}"
      )

      return [] if blocks.compact.empty?

      if blocks.size > 1
        warn "⚠️ [heading_block] Multiple blocks detected (#{blocks.size}) — expected single rich_text block. Context: #{context}"
      end

      first_block = blocks.shift
      rich_text = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [heading_block] Building heading level #{level} block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "heading_block rich_text")

      [{
        object: "block",
        type: "heading_#{level}",
        "heading_#{level}": { rich_text: rich_text }
      }] + embed_blocks.compact
    end

    # ✅ Callout block helper
    def self.callout_block(text, emoji = "💬", context = nil)
      blocks, _media_files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
        text,
        nil,
        "CalloutBlock#{context ? " (#{context})" : ""}"
      )

      return [] if blocks.compact.empty?

      if blocks.size > 1
        warn "⚠️ [callout_block] Multiple blocks detected (#{blocks.size}) — expected single rich_text block. Context: #{context}"
      end

      first_block = blocks.shift
      rich_text = (first_block.dig(:paragraph, :rich_text) || []).compact
      return [] if rich_text.empty?

      debug "🧩 [callout_block] Building callout block for context: #{context}, rich_text size: #{rich_text.size}"
      debug_rich_text_preview(rich_text, context: context, label: "callout_block rich_text")

      [{
        object: "block",
        type: "callout",
        callout: {
          icon: { type: "emoji", emoji: emoji },
          rich_text: rich_text
        }
      }] + embed_blocks.compact
    end

    # ✅ Label + link block
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
      }.tap do |block|
        debug "[image_block] => #{block.inspect} (#{context})"
      end
    end

    # ✅ PDF embed block
    def self.pdf_file_block(url, context)
      return [] unless url && !url.strip.empty?

      {
        object: 'block',
        type: 'file',
        file: {
          type: 'external',
          external: { url: url }
        }
      }.tap do |block|
        debug "[pdf_file_block] => #{block.inspect} (#{context})"
      end
    end

    # ✅ Divider block
    def self.divider_block
      debug "🧩 [divider_block] Creating divider block"
      { object: "block", type: "divider", divider: {} }
    end

    # ✅ Index link block
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

    # ✅ Comment section wrapper
    def self.comment_section_block(comment_blocks, context = nil)
      compacted_comments = deep_compact_blocks(comment_blocks)
      return [] if compacted_comments.empty?

      debug "🗨️ [comment_section_block] Building comment section block with #{compacted_comments.size} inner blocks (#{context})"

      [
        divider_block,
        heading_block("🗨️ Comments:", 2, context),
        *compacted_comments,
        divider_block
      ].flatten.compact
    end

    # ✅ Comment author callout
    def self.comment_author_block(author_name, created_at, context = nil)
      debug "🧩 [comment_author_block] Building comment author block for #{author_name} at #{created_at} (#{context})"
      callout_block("👤 #{author_name} · 🕗 #{created_at}", "💬", context).compact
    end

    # ✅ Callout wrapper
    def self.wrap_in_callout(blocks, text = "Additional context", emoji = "💬")
      compacted_blocks = deep_compact_blocks(blocks)
      return compacted_blocks if compacted_blocks.empty?

      debug "🧩 [wrap_in_callout] Wrapping #{compacted_blocks.size} blocks in callout"

      [
        {
          object: "block",
          type: "callout",
          callout: {
            icon: { type: "emoji", emoji: emoji },
            rich_text: [{
              type: "text",
              text: { content: text }
            }]
          }
        },
        *compacted_blocks
      ].flatten.compact
    end

    def self.basecamp_asset_fallback_blocks(url, caption, context)
      debug "📎 [basecamp_asset_fallback_blocks] Creating fallback callout for #{url} (#{context})"

      cleaned = url.to_s.strip
      uri = URI.parse(cleaned) rescue nil
      link_obj = uri&.scheme&.match?(/^https?$/) ? { url: cleaned } : nil

      return [] unless link_obj

      main_richtext = []
      main_richtext << {
        type: 'text',
        text: {
          content: 'Basecamp asset',
          link: link_obj
        }
      }
      if caption && !caption.empty?
        main_richtext << {
          type: 'text',
          text: { content: " – #{caption}" }
        }
      end

      [
        {
          object: 'block',
          type: 'callout',
          callout: {
            icon: { type: 'emoji', emoji: '🔗' },
            rich_text: main_richtext,
            color: 'yellow_background'
          }
        }
      ]
    end

    # ✅ Utility: debug preview
    def self.debug_block_previews(blocks, context:, label:)
      return if blocks.empty?
      debug "🧩 [#{label}] Previewing first #{[blocks.size, 5].min} blocks (#{context}):"
      blocks.first(5).each_with_index do |block, idx|
        debug "    [#{label} block #{idx}] #{block.to_json[0..500]}"
      end
    end

    # ✅ Utility: rich_text preview
    def self.debug_rich_text_preview(rich_text_array, context:, label:)
      return if rich_text_array.empty?
      debug "🧩 [#{label}] RichText preview (#{context}): total #{rich_text_array.size} items"
      rich_text_array.each_with_index do |text, idx|
        preview = text.dig(:text, :content).to_s[0..60]
        debug "    [#{label} item #{idx}] Content preview: '#{preview}'"
      end
    end

    # ✅ Utility: compact block filter
    def self.deep_compact_blocks(blocks)
      (blocks || []).compact.reject { |block| block.nil? || block == {} }
    end
  end
end
