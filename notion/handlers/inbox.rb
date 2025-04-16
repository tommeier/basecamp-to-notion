# /notion/handlers/inbox.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Inbox
      extend ::Utils::Logging

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling inbox tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/forwards.json')
        forwards = Basecamp::Fetch.load_json(URI(url), headers)

        if forwards.empty?
          log "📭 No inbox forwards found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total inbox forwards to process: #{forwards.size}"

        blocks = []

        forwards.each_with_index do |forward, idx|
          context = "Inbox Forward #{idx + 1}: #{forward["subject"]}"

          # ✅ Progress: upsert item at start
          progress.upsert_item(
            basecamp_id: forward["id"],
            project_basecamp_id: project["id"],
            tool_name: "inbox"
          )

          # ✅ Forward subject as heading
          blocks += Notion::Helpers.heading_blocks("📥 #{forward["subject"]}", 3, context)

          # ✅ Forward body (description)
          if forward["description"] && !forward["description"].strip.empty?
            media_blocks, embed_blocks = ::Utils::MediaExtractor.extract_blocks(
              forward["description"],
              parent_page_id,
              context
            )
            blocks += media_blocks if media_blocks.any?
            blocks += embed_blocks if embed_blocks.any?
          end

          # ✅ Forward URL
          if forward["app_url"]
            blocks << Notion::Helpers.label_and_link_block("🔗", forward["app_url"], context)
          end

          blocks << Notion::Helpers.divider_block

          # ✅ Progress: mark item complete
          progress.complete_item(forward["id"], project["id"], "inbox")
        end

        log "🧩 InboxHandler: Prepared #{blocks.size} blocks for #{tool['title']}'"

        # ✅ Sanitize and append safely
        Notion::Blocks.append(parent_page_id, blocks, context: "Inbox #{tool['title']}")

        # ✅ Return index block for tool index page
        index_block = Notion::Helpers.index_link_block(parent_page_id, tool['title'], "📥")
        [index_block].compact
      end
    end
  end
end
