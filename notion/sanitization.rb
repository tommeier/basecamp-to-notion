# notion/sanitization.rb

require_relative '../utils/logging'

module Notion
  module Sanitization
    extend ::Utils::Logging

    def self.sanitize_blocks(blocks, context = nil)
      prefix = context ? "[#{context}] " : ""
      original_count = blocks.size

      log "🧹 Entering sanitize_blocks: #{original_count} blocks"

      # Step 1: Defensive clone and compact
      blocks = blocks.map do |b|
        begin
          JSON.parse(b.to_json) if b.is_a?(Hash)
        rescue => e
          warn "🚫 #{prefix}Failed to clone block safely: #{e.message} — Skipping block: #{b.inspect}"
          nil
        end
      end.compact

      # Step 2: Pre-filter obvious invalids
      blocks = blocks.select.with_index do |block, idx|
        if !block.is_a?(Hash)
          warn "🚫 #{prefix}Block at index #{idx} is not a Hash: #{block.inspect}. Skipping."
          next false
        end

        if block["type"].nil?
          warn "🚫 #{prefix}Block at index #{idx} missing type. Skipping."
          next false
        end

        if block[block["type"]].nil?
          warn "🚫 #{prefix}Block at index #{idx} missing container for type '#{block["type"]}'. Skipping."
          next false
        end

        true
      end

      log "🧹 Preview of first 5 blocks before sanitization:"
      blocks.first(5).each_with_index do |block, idx|
        block_size = estimate_block_size(block)
        log "  [#{idx}] #{block.to_json[0..500]} (est. size: #{block_size} bytes)"
      end

      sanitized = blocks.map.with_index do |block, index|
        block_type = block["type"]
        container = block[block_type] || {}

        # Optional: Check estimated block size (for debugging payload issues)
        block_size = estimate_block_size(block)
        log "🧩 #{prefix}Block at index #{index} estimated size: #{block_size} bytes"

        # Focus on rich_text based blocks
        if %w[paragraph callout heading_1 heading_2 heading_3 bulleted_list_item numbered_list_item].include?(block_type)
          unless container.is_a?(Hash)
            warn "🚫 #{prefix}Block at index #{index} container is not Hash for '#{block_type}': #{block.inspect}"
            next nil
          end

          rich_text = container["rich_text"] || []
          original_rich_text = rich_text.dup

          unless rich_text.is_a?(Array)
            warn "🚫 #{prefix}Block at index #{index} rich_text is not Array: #{block.inspect}"
            next nil
          end

          initial_count = rich_text.size
          rich_text.reject! do |text_segment|
            safe_text_content(text_segment).strip.empty? && safe_link_url(text_segment).strip.empty?
          end
          removed_count = initial_count - rich_text.size

          if removed_count > 0
            log "🧹 #{prefix}Removed #{removed_count} empty rich_text items in block at index #{index}"
          end

          if rich_text.empty?
            if original_rich_text.any? { |t| safe_link_url(t).strip != "" }
              log "🧩 #{prefix}Preserving fallback link in block at index #{index}"
              container["rich_text"] = original_rich_text
            else
              warn "🚫 #{prefix}Block at index #{index} has empty rich_text. Removing block."
              next nil
            end
          end
        end

        # Optional: Log children count
        children_count = (block["children"] || []).size rescue 0
        log "🧹 #{prefix}Block at index #{index} — type: #{block_type}, children: #{children_count}"

        block
      end.compact

      removed_count = original_count - sanitized.size
      if removed_count > 0
        log "🧹 #{prefix}Sanitizer: Removed #{removed_count} invalid or empty blocks out of #{original_count}"
      end

      sanitized.each_with_index do |block, idx|
        next if idx >= 5
        log "🧹 Post-sanitize block #{idx}: #{block.to_json[0..500]}"
      end

      log "🧹 Final sanitized block count: #{sanitized.size}"

      sanitized
    end

    # Helpers
    def self.safe_text_content(text_segment)
      text_segment.is_a?(Hash) ? text_segment.dig("text", "content").to_s : ""
    end

    def self.safe_link_url(text_segment)
      text_segment.is_a?(Hash) ? text_segment.dig("text", "link", "url").to_s : ""
    end

    def self.safe_notion_text(text)
      text = text.to_s
      text.gsub!("\u200B", '') # Zero-width space
      text.gsub!("\u00A0", ' ') # Non-breaking space
      text.gsub!(/<[^>]+>/, '') # Strip HTML tags
      text.encode!('UTF-8', invalid: :replace, undef: :replace, replace: '�')
      text.strip
    rescue => e
      error "❌ Error sanitizing text: #{e.message}"
      text
    end

    # Estimate JSON block size
    def self.estimate_block_size(block)
      JSON.generate(block).bytesize
    rescue
      1000 # fallback if invalid
    end

    def self.deep_sanitize_blocks(blocks, context = nil)
      sanitize_blocks(blocks, context).map do |block|
        if block["children"]
          block["children"] = deep_sanitize_blocks(block["children"], context)
        end
        block
      end
    end
  end
end
