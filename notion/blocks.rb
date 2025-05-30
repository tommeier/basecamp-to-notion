# notion/blocks.rb

require_relative "../config"
require_relative "../utils/logging"
require_relative "../utils/block_validator"
require_relative "./api"
require_relative "./pages"
require_relative "./sanitization"
require_relative "./utils"

module Notion
  module Blocks
    extend ::Utils::Logging

    # MAX_BLOCKS_PER_REQUEST, MAX_PAYLOAD_BYTES, and MAX_CHILDREN_PER_BLOCK
    # are now defined in config.rb and loaded from environment variables.
    # They are available as top-level constants: 
    # ::NOTION_BATCH_MAX_BLOCKS, ::MAX_NOTION_PAYLOAD_BYTES, ::MAX_CHILDREN_PER_BLOCK

    def self.extract_blocks(html, parent_page_id, context)
      notion_blocks = []
      embed_blocks = []
      failed_attachments_details = []

      doc = Nokogiri::HTML::DocumentFragment.parse(html)

      doc.children.each do |child|
        next unless child.element?
        ::Utils::MediaExtractor::Handlers.handle_node_recursive(child, context, parent_page_id, notion_blocks, embed_blocks, failed_attachments_details)
      end

      [notion_blocks.compact, embed_blocks.compact]
    end

    def self.append_batched(page_id, blocks, context: nil)
      context ||= "Page: #{page_id}"
      batches = blocks.each_slice(MAX_BLOCKS_PER_REQUEST).to_a
      log "🧩 [append_batched] Splitting into #{batches.size} batches of up to #{MAX_BLOCKS_PER_REQUEST} blocks (#{context})"

      batches.each_with_index do |block_batch, batch_index|
        append(page_id, block_batch, context: "#{context} Batch #{batch_index + 1}")
      end
    end

    def self.append(page_id, blocks, context: nil)
      context ||= "Page: #{page_id}"
      return warn "🚫 [append] page_id is nil. Skipping append. Context: #{context}" if page_id.nil?

      block_id = Notion::Utils.format_uuid(page_id, context: context)
      log "📄 [append] Appending to Notion page block_id: #{block_id}#{context ? " (#{context})" : ""}"

      blocks = Notion::Sanitization.sanitize_blocks(blocks, context: context)
      blocks = blocks.map { |b| b.is_a?(Hash) ? b.transform_keys(&:to_s) : b }

      blocks.flatten!
      blocks.compact!
      blocks.reject! { |b| b.nil? || !b.is_a?(Hash) || b["type"].nil? }
      blocks.reject! { |b| b.respond_to?(:empty?) && b.empty? }

      if blocks.empty?
        warn "⚠️ [append] No blocks to append for page #{block_id}#{context ? " (#{context})" : ""} — skipping append."
        return
      end

      $global_block_count += blocks.size

      # Log diagnostics
      log "🧩 [append] Pre-split: total blocks: #{blocks.size} (#{context})"
      blocks.each_with_index do |block, idx|
        children_count = (block["children"] || []).size rescue 0
        block_size = estimate_block_size(block)
        debug "    [block #{idx}] type='#{block["type"]}', size=#{block_size} bytes, children=#{children_count}"
      end

      # Split large children (blocks with too many internal children).
      # This uses ::MAX_CHILDREN_PER_BLOCK from config.rb for splitting criteria.
      # The ::MAX_NOTION_PAYLOAD_BYTES argument is passed but not used by split_large_blocks for its splitting logic.
      blocks = split_large_blocks(blocks, ::MAX_CHILDREN_PER_BLOCK, context)

      # Split by payload size
      payload_batches = split_blocks_by_payload_size(blocks, ::MAX_NOTION_PAYLOAD_BYTES)
      log "🧩 [append] Payload-split into #{payload_batches.size} groups (#{context})"

      # Enforce max blocks per request
      final_batches = payload_batches.flat_map { |batch| batch.each_slice(::NOTION_BATCH_MAX_BLOCKS).to_a }
      log "🧩 [append] Final sliced into #{final_batches.size} batches (max #{::NOTION_BATCH_MAX_BLOCKS} blocks per batch) (#{context})"

      final_batches.each_with_index do |block_slice, idx|
        next if block_slice.nil? || block_slice.empty? || block_slice.all? { |b| !b.is_a?(Hash) || b["type"].nil? }

        debug "🧩 [append] Preparing batch #{idx + 1}/#{final_batches.size} — #{block_slice.size} blocks"

        block_slice.each_with_index do |block, block_idx|
          if block["children"].is_a?(Array)
            before = block["children"].size
            block["children"].compact!
            block["children"].reject! { |child| !child.is_a?(Hash) || child.empty? || child["type"].nil? }
            after = block["children"].size
            removed = before - after
            log "🧹 [append] Cleaned children for block #{block_idx}: removed #{removed} invalid children" if removed > 0
          end
        end

        valid_block_count, invalid_block_count = BlockValidator.validate_blocks(block_slice, context)
        log "🧩 [append] Block validation: #{valid_block_count} valid, #{invalid_block_count} invalid"

        # Filter out blocks that don't pass basic validation before sending to API
        # BlockValidator.valid_block? checks if it's a Hash and has a 'type' key.
        original_count = block_slice.size
        block_slice.select! { |block| ::BlockValidator.valid_block?(block) }
        filtered_count = block_slice.size
        if original_count != filtered_count
          log "🗑️ [append] Removed #{original_count - filtered_count} invalid blocks from batch before sending. Original: #{original_count}, Final: #{filtered_count}"
        end

        # Re-check if block_slice is empty after filtering, as it might now be.
        next if block_slice.empty?

        payload = { children: block_slice }
        debug "📦 [append] Final payload size: #{JSON.generate(payload).bytesize} bytes"

        begin
          Notion::API.patch_json(
            "https://api.notion.com/v1/blocks/#{block_id}/children",
            payload,
            Notion::API.default_headers,
            context: context
          )
          log "✅ [append] Successfully appended batch #{idx + 1}/#{final_batches.size} (#{block_slice.size} blocks)"
        rescue => e
          failing_preview = block_slice.first ? JSON.pretty_generate(block_slice.first)[0..500] : "No blocks in slice"
          error "❌ [append] Error appending to #{block_id}: #{e.message}"
          error "🔍 First block:\n#{failing_preview}"
          raise e
        end
      end
    end

    def self.split_blocks_by_payload_size(blocks, max_bytes)
      batches = []
      return batches if blocks.empty?

      current_batch = []

      blocks.each do |block|
        # Calculate the prospective size if this block were added to the current_batch
        prospective_payload_for_check = { children: current_batch + [block] }
        estimated_size_if_added = JSON.generate(prospective_payload_for_check).bytesize

        if !current_batch.empty? && estimated_size_if_added > max_bytes
          # The current block would make the current_batch + block too large.
          # Finalize the current_batch (without this block) and add it to batches.
          batches << current_batch
          # Start a new batch with the current block.
          current_batch = [block]
        else
          # It's safe to add this block to the current_batch (either it fits, or current_batch is empty).
          # If current_batch is empty, this block starts a new batch, regardless of its individual size here.
          # An individual block exceeding max_bytes will form its own batch, to be potentially caught by HTTP layer.
          current_batch << block
        end
      end

      # Add the last remaining batch if it's not empty
      batches << current_batch unless current_batch.empty?
      batches
    end

    def self.split_large_blocks(blocks, max_children_per_block, context = nil)
      split_blocks = []

      blocks.each_with_index do |block, idx|
        children = block["children"]
        if children.is_a?(Array) && children.size > max_children_per_block
          log "🚨 [split_large_blocks] Splitting block #{idx} (#{block["type"]}) with #{children.size} children"
          children.each_slice(max_children_per_block).with_index do |child_slice, slice_idx|
            new_block = block.dup
            new_block["children"] = child_slice
            log "    ↪️ Created sub-block #{slice_idx + 1} with #{child_slice.size} children"
            split_blocks << new_block
          end
        else
          split_blocks << block
        end
      end

      split_blocks
    end

    def self.estimate_block_size(block)
      JSON.generate(block).bytesize
    rescue
      1000
    end

    def self.estimate_batch_size(batch)
      batch.sum { |block| estimate_block_size(block) }
    end
  end
end
