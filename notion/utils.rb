# /notion/utils.rb

require 'time'
require_relative "../utils/logging"
require_relative "./constants"
require_relative "./pages"

module Notion
  module Utils
    extend ::Utils::Logging

    # ✅ UUID formatter
    def self.format_uuid(id, context: nil)
      unless id.is_a?(String)
        warn "⚠️ format_uuid received nil or invalid input: #{id.inspect}#{context ? " (#{context})" : ""}\nCaller: #{caller(1..3).join("\n")}"
        return nil
      end

      return id if id.include?('-') && id.length == 36

      clean = id.delete("-")
      unless clean.length == 32
        raise "🚫 Invalid Notion UUID: #{id}#{context ? " (#{context})" : ""}"
      end

      "#{clean[0..7]}-#{clean[8..11]}-#{clean[12..15]}-#{clean[16..19]}-#{clean[20..31]}"
    end

    def self.validate_notion_uuid(id)
      raise "🚫 Invalid Notion block ID: #{id}" unless id =~ /^[0-9a-f\-]{36}$/
    end

    def self.valid_notion_uuid?(id)
      !!(id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    end

    def self.format_timestamp(timestamp)
      Time.parse(timestamp).strftime("%Y-%m-%d %H:%M")
    rescue StandardError
      timestamp
    end

    def self.split_blocks_into_subpages(blocks, base_title, emoji, parent_id, parent_tool_url:, limit: Notion::MAX_BLOCKS_PER_TOOL_PAGE - 1)
      raise "🚫 parent_id is nil for split_blocks_into_subpages (#{base_title})" if parent_id.nil?
      raise "🚫 blocks is nil for split_blocks_into_subpages (#{base_title})" if blocks.nil?

      subpages = []
      total_batches = (blocks.size.to_f / limit).ceil

      blocks.each_slice(limit).with_index do |batch_blocks, index|
        subpage_title = "#{base_title} (Part #{index + 1})"
        context = "Subpage #{index + 1} for #{base_title}"

        log "📝 Creating subpage: #{subpage_title} with #{batch_blocks.size} blocks"

        initial_blocks = batch_blocks.first(Notion::MAX_BLOCKS_PER_PAGE_CREATION - Notion::MIGRATION_BANNER_BLOCKS)
        remaining_blocks = batch_blocks.drop(Notion::MAX_BLOCKS_PER_PAGE_CREATION)

        subpage = Notion::Pages.create_page(
          { "name" => subpage_title, "url" => parent_tool_url },
          parent_id,
          children: initial_blocks,
          context: context,
          url: parent_tool_url
        )

        subpage_id = subpage&.dig("id")
        unless subpage_id
          error "🚫 Failed to create subpage: #{subpage_title}"
          next
        end

        if remaining_blocks.any?
          log "📦 Appending #{remaining_blocks.size} blocks to subpage: #{subpage_title}"
          Notion::Blocks.append(subpage_id, remaining_blocks, context: context)
        end

        subpages << { id: subpage_id, title: subpage_title }
        log "✅ Finished subpage #{index + 1}/#{total_batches}: #{subpage_title}"
      end

      subpages
    end
  end
end
