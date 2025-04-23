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

    MAX_BLOCKS_PER_REQUEST = 100
    MAX_PAYLOAD_BYTES = 700_000
    MAX_CHILDREN_PER_BLOCK = 50

    def self.extract_blocks(html, parent_page_id, context)
      notion_blocks = []
      embed_blocks = []

      doc = Nokogiri::HTML::DocumentFragment.parse(html)

      doc.children.each do |child|
        next unless child.element?
        ::Utils::MediaExtractor::Handlers.handle_node_recursive(child, context, parent_page_id, notion_blocks, embed_blocks)
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

      # Split large children
      blocks = split_large_blocks(blocks, MAX_PAYLOAD_BYTES, MAX_CHILDREN_PER_BLOCK, context)

      # Split by payload size
      payload_batches = split_blocks_by_payload_size(blocks, MAX_PAYLOAD_BYTES)
      log "🧩 [append] Payload-split into #{payload_batches.size} groups (#{context})"

      # Enforce max 100 blocks per request
      final_batches = payload_batches.flat_map { |batch| batch.each_slice(MAX_BLOCKS_PER_REQUEST).to_a }
      log "🧩 [append] Final sliced into #{final_batches.size} batches (#{context})"

      final_batches.each_with_index do |block_slice, idx|
        next if block_slice.nil? || block_slice.empty? || block_slice.all? { |b| !b.is_a?(Hash) || b["type"].nil? }

        debug "🧩 [append] Preparing batch #{idx + 1}/#{final_batches.size} — #{block_slice.size} blocks"

        block_slice.each_with_index do |block, block_idx|
          if block["children"].is_a?(Array)
            before = block["children"].size
            block["children"].compact!
            block["children"].reject! { |child| child.nil? || !child.is_a?(Hash) || child.empty? || child["type"].nil? }
            after = block["children"].size
            removed = before - after
            log "🧹 [append] Cleaned children for block #{block_idx}: removed #{removed} invalid children" if removed > 0
          end
        end

        valid_block_count, invalid_block_count = BlockValidator.validate_blocks(block_slice, context)
        log "🧩 [append] Block validation: #{valid_block_count} valid, #{invalid_block_count} invalid"

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
      current_batch = []
      current_size = 0

      blocks.each do |block|
        size = estimate_block_size(block)
        if current_size + size > max_bytes
          batches << current_batch unless current_batch.empty?
          current_batch = []
          current_size = 0
        end

        current_batch << block
        current_size += size
      end

      batches << current_batch unless current_batch.empty?
      batches
    end

    def self.split_large_blocks(blocks, max_payload_bytes, max_children_per_block, context = nil)
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
