# /notion/handlers/kanban_board.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module KanbanBoard
      extend ::Utils::Logging

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling kanban_board tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/columns.json')
        columns = Basecamp::Fetch.load_json(URI(url), headers)

        if columns.empty?
          log "📭 No kanban columns found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total kanban columns to process: #{columns.size}"

        blocks = []

        columns.each_with_index do |column, idx|
          context = "Kanban Column #{idx + 1}: #{column["name"]}"
          raw_preview = column.to_json[0..500]
          log "🧩 Raw Basecamp column #{idx + 1}/#{columns.size}: #{raw_preview}"

          item_blocks = []

          # ✅ Column title
          item_blocks += Notion::Helpers.heading_block("🗂️ #{column["name"]}", 3, context)

          if column["cards_count"] == 0
            item_blocks += Notion::Helpers.text_block("📭 No cards in this column", context)
            blocks += item_blocks
            next
          end

          cards_url = column["url"].sub(/\.json$/, '/cards.json')
          cards = Basecamp::Fetch.load_json(URI(cards_url), headers)

          if cards.empty?
            item_blocks += Notion::Helpers.text_block("📭 No cards found in column", context)
            blocks += item_blocks
            next
          end

          log "🧩 Found #{cards.size} cards in column '#{column["name"]}'"

          cards.each_with_index do |card, card_idx|
            card_context = "Kanban Card #{card_idx + 1}: #{card["title"]}"
            raw_card_preview = card.to_json[0..500]
            log "🧩 Raw Basecamp card #{card_idx + 1}/#{cards.size}: #{raw_card_preview}"

            # ✅ Progress: upsert item at start
            progress.upsert_item(
              basecamp_id: card["id"],
              project_basecamp_id: project["id"],
              tool_name: "kanban_board"
            )

            card_blocks = []

            # ✅ Card title
            card_blocks += Notion::Helpers.callout_block(card["title"], "🗂️", card_context)

            # ✅ Creator metadata
            if card["creator"]
              creator_name = card["creator"]["name"] || "Unknown"
              created_at = Notion::Utils.format_timestamp(card["created_at"]) rescue "Unknown date"
              card_blocks += Notion::Helpers.callout_block("👤 Created by #{creator_name} · 🕗 #{created_at}", "🖊️", card_context)
            end

            # ✅ Card description
            if card["description"] && !card["description"].strip.empty?
              content_blocks, embed_blocks = Notion::Blocks.extract_blocks(card["description"], parent_page_id, card_context)

              card_blocks += content_blocks if content_blocks.any?
              card_blocks += embed_blocks if embed_blocks.any?
            end

            # ✅ Card link
            card_blocks << Notion::Helpers.label_and_link_block("🔗", card["app_url"], context) if card["app_url"]

            # ✅ Divider
            card_blocks << Notion::Helpers.divider_block

            item_blocks += card_blocks

            # ✅ Progress: mark item complete
            progress.complete_item(card["id"], project["id"], "kanban_board")
          end

          blocks += item_blocks
        end

        log "🧩 KanbanBoardHandler: Prepared #{blocks.size} blocks for #{tool['title']}'"

        Notion::Blocks.append_batched(parent_page_id, blocks, context: "KanbanBoard #{tool['title']}'")

        index_block = Notion::Helpers.index_link_block(parent_page_id, tool['title'], "🗂️")
        [index_block].compact
      end
    end
  end
end
