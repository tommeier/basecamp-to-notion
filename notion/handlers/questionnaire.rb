# /notion/handlers/questionnaire.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Questionnaire
      extend ::Utils::Logging

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling questionnaire tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/questions.json')
        questions = Basecamp::Fetch.load_json(URI(url), headers)

        if questions.empty?
          log "📭 No questions found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total questions to process: #{questions.size}"

        blocks = []

        questions.each_with_index do |question, idx|
          begin
            context = "Questionnaire Q#{idx + 1}: #{question["subject"]}"
            raw_preview = question.to_json[0..500]
            log "🧩 Raw Basecamp question #{idx + 1}/#{questions.size}: #{raw_preview}"

            # ✅ Progress: upsert item at start
            progress.upsert_item(
              basecamp_id: question["id"],
              project_basecamp_id: project["id"],
              tool_name: "questionnaire"
            )

            item_blocks = []

            # ✅ Question title
            item_blocks += Notion::Helpers.heading_blocks("❓ #{question["subject"]}", 3, context)

            # ✅ Creator metadata
            if question["creator"]
              creator_name = question["creator"]["name"] || "Unknown"
              created_at = Notion::Utils.format_timestamp(question["created_at"]) rescue "Unknown date"
              item_blocks += Notion::Helpers.callout_blocks("👤 Created by #{creator_name} · 🕗 #{created_at}", "📝", context)
            end

            # ✅ Description
            if question["description"] && !question["description"].strip.empty?
              content_blocks, embed_blocks = Notion::Blocks.extract_blocks(question["description"], parent_page_id, context)

              item_blocks += content_blocks if content_blocks.any?
              item_blocks += embed_blocks if embed_blocks.any?
            end

            # ✅ Link to original
            item_blocks << Notion::Helpers.label_and_link_block("🔗", question["app_url"], context) if question["app_url"]

            # ✅ Final divider
            item_blocks << Notion::Helpers.divider_block

            blocks += item_blocks

            # ✅ Progress: mark item complete
            progress.complete_item(question["id"], project["id"], "questionnaire")
          rescue => e
            warn "❌ Error processing questionnaire question #{question["id"]}: #{e.class}: #{e.message}"
            warn "  Full question content: #{question.inspect}"
            warn "  Exception backtrace:\n#{e.backtrace.join("\n")}"
            next
          end
        end

        log "🧩 QuestionnaireHandler: Prepared #{blocks.size} blocks for #{tool['title']}'"

        Notion::Blocks.append_batched(parent_page_id, blocks, context: "Questionnaire #{tool['title']}")

        log "📦 QuestionnaireHandler: Finished processing '#{tool['title']}'"
        []
      end
    end
  end
end
