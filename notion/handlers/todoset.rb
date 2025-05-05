# /notion/handlers/todoset.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Todoset
      extend ::Utils::Logging

      MAX_TODOS_PER_PAGE = 100

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling todoset tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/todosets.json')
        todosets = Basecamp::Fetch.load_json(URI(url), headers)

        if todosets.empty?
          log "📭 No todo sets found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total todo sets: #{todosets.size}"

        todosets.each_with_index do |todoset, set_idx|
          set_title = todoset["name"] || "Untitled Todoset #{set_idx + 1}"
          todos_url = todoset["url"].sub(/\.json$/, '/todos.json')
          todos = Basecamp::Fetch.load_json(URI(todos_url), headers)

          if todos.empty?
            log "📭 Empty todoset: #{set_title}"
            next
          end

          todo_chunks = todos.each_slice(MAX_TODOS_PER_PAGE).to_a
          needs_subpages = todo_chunks.size > 1

          parent_set_page = if needs_subpages
            Notion::Pages.create_page(
              { "name" => "✅ #{set_title}", "url" => tool["url"] },
              parent_page_id,
              children: [],
              context: "Todoset Parent Page",
              url: tool["url"]
            )
          end

          todo_chunks.each_with_index do |chunk, chunk_idx|
            page_title = needs_subpages ? "✅ #{set_title} (Part #{chunk_idx + 1})" : "✅ #{set_title}"
            sub_page_parent = needs_subpages ? parent_set_page["id"] : parent_page_id

            page = Notion::Pages.create_page(
              { "name" => page_title, "url" => tool["url"] },
              sub_page_parent,
              children: [],
              context: "Todoset Subpage #{chunk_idx + 1}",
              url: tool["url"]
            )
            page_id = page["id"]

            unless page_id
              warn "🚫 Skipping todoset subpage #{chunk_idx + 1}: page creation failed."
              next
            end

            log "🧩 Created todoset page: #{page_id} for Part #{chunk_idx + 1} with #{chunk.size} todos"

            blocks = []

            chunk.each_with_index do |todo, todo_idx|
              begin
                context = "Todo #{todo_idx + 1} of #{chunk.size}: #{todo['title']}"
                raw_preview = todo.to_json[0..500]
                log "🧩 Raw Basecamp todo #{todo_idx + 1}/#{chunk.size}: #{raw_preview}"

                # ✅ Progress: upsert item at start
                progress.upsert_item(
                  basecamp_id: todo["id"],
                  project_basecamp_id: project["id"],
                  tool_name: "todoset"
                )

                item_blocks = []

                # ✅ Todo title as to-do block
                item_blocks << {
                  object: "block",
                  type: "to_do",
                  to_do: {
                    checked: todo["completed"],
                    rich_text: [{ type: "text", text: { content: todo["title"] } }]
                  }
                }

                # ✅ Creator metadata
                if todo["creator"]
                  creator_name = todo["creator"]["name"] || "Unknown"
                  created_at = Notion::Utils.format_timestamp(todo["created_at"]) rescue "Unknown date"
                  item_blocks += Notion::Helpers.callout_blocks("👤 Created by #{creator_name} · 🕗 #{created_at}", "📝", context)
                end

                # ✅ Description
                if todo["description"] && !todo["description"].strip.empty?
                  content_blocks, embed_blocks = Notion::Blocks.extract_blocks(todo["description"], page_id, context)

                  item_blocks += content_blocks if content_blocks.any?
                  item_blocks += embed_blocks if embed_blocks.any?
                end

                # ✅ App URL
                item_blocks << Notion::Helpers.label_and_link_block("🔗", todo["app_url"], context) if todo["app_url"]

                # ✅ Divider
                item_blocks << Notion::Helpers.divider_block

                blocks += item_blocks

                # ✅ Progress: mark item complete
                progress.complete_item(todo["id"], project["id"], "todoset")
              rescue => e
                warn "❌ Error processing todo #{todo["id"]}: #{e.class}: #{e.message}"
                warn "  Full todo content: #{todo.inspect}"
                warn "  Exception backtrace:\n#{e.backtrace.join("\n")}"
                next
              end
            end

            log "🧩 Prepared #{blocks.size} blocks for Todoset Part #{chunk_idx + 1}"

            Notion::Blocks.append_batched(page_id, blocks, context: "Todoset Part #{chunk_idx + 1} - #{set_title}")
          end
        end

        log "📦 TodosetHandler: Finished processing '#{tool['title']}'"
        []
      end
    end
  end
end
