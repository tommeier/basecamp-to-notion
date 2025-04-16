# /notion/handlers/chat.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require_relative '../utils'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Chat
      extend ::Utils::Logging

      BATCH_LIMIT = 100

      def self.call(project, tool, parent_id, headers, progress)
        log "🔧 Handling chat tool: #{tool['title']}"
        chat_url = tool["url"].sub(/\.json$/, '/lines.json')
        lines = Basecamp::Fetch.load_json(URI(chat_url), headers)

        if lines.empty?
          log "📝 No chat lines found for #{tool['title']}'"
          return []
        end

        log "🧩 Total chat lines to process: #{lines.size}"

        tool_page_id = parent_id

        lines_by_year = lines.group_by do |line|
          Date.parse(line["created_at"]).year rescue 'Unknown'
        end

        lines_by_year.sort_by { |year, _| year }.each do |year, lines_in_year|
          log "📝 Creating chat page for year '#{year}' with #{lines_in_year.size} lines"

          sorted_lines_in_year = lines_in_year.sort_by { |line| line["created_at"] }

          first_line_date = sorted_lines_in_year.map { |line| line["created_at"] }.compact.min
          date_part = first_line_date ? " (#{Notion::Utils.format_timestamp(first_line_date).split(' ').first})" : ""

          first_line_url = sorted_lines_in_year.first["app_url"] || tool["url"]

          year_page = Notion::Pages.create_page(
            { "name" => "💬 Chat: #{tool['title']}#{date_part}", "url" => first_line_url },
            tool_page_id,
            children: [],
            context: "Chat Year #{year}",
            url: first_line_url
          )
          year_page_id = year_page&.dig("id")

          if year_page_id.nil?
            warn "🚫 Skipping chat year page for #{year} due to nil page ID"
            next
          end

          message_chunks = sorted_lines_in_year.each_slice(BATCH_LIMIT).to_a

          if message_chunks.size == 1
            log "🧩 Single batch for chat year '#{year}', appending directly to year page."

            # ✅ Track per "chunk" as batch
            blocks = build_chat_blocks(message_chunks.first, tool, year_page_id, 1, year, project, progress)
            Notion::Blocks.append_batched(year_page_id, blocks, context: "Chat Year #{year}")
          else
            message_chunks.each_with_index do |chunk, index|
              message_url = chunk.first["app_url"] || tool["url"]
              page_title = "💬 Chat: #{tool['title']}#{date_part} (Part #{index + 1})"

              part_page = Notion::Pages.create_page(
                { "name" => page_title, "url" => message_url },
                year_page_id,
                children: [],
                context: "Chat Year #{year} Part #{index + 1}",
                url: message_url
              )
              page_id = part_page["id"]

              unless page_id
                warn "🚫 Skipping subpage #{index + 1}: page creation failed."
                next
              end

              log "📄 Created chat page: #{page_id} for #{page_title} with #{chunk.size} lines"

              blocks = build_chat_blocks(chunk, tool, page_id, index + 1, year, project, progress)

              log "🧩 Prepared #{blocks.size} blocks for Chat Year #{year} Part #{index + 1}"

              Notion::Blocks.append_batched(page_id, blocks, context: "Chat Year #{year} Part #{index + 1}")
            end
          end
        end

        log "📦 ChatHandler: Finished processing '#{tool['title']}'"
        []
      end

      def self.build_chat_blocks(lines, tool, page_id, batch_number, year, project, progress)
        blocks = []

        lines.each_with_index do |line, idx|
          next if line["content"].nil? || line["content"].strip.empty?

          context = "Chat #{year} Batch #{batch_number} Line #{idx + 1}"
          raw_preview = line.to_json[0..500]
          log "🧩 Raw Basecamp line #{idx + 1}/#{lines.size} in batch #{batch_number}: #{raw_preview}"

          # ✅ Progress: upsert item at start
          progress.upsert_item(
            basecamp_id: line["id"],
            project_basecamp_id: project["id"],
            tool_name: "chat"
          )

          line_blocks = []

          # 🧩 Author callout
          author = line.dig("creator", "name") || "Unknown author"
          created_at = line["created_at"] ? Notion::Utils.format_timestamp(line["created_at"]) : "Unknown date"
          author_line = "#{author} (#{created_at}):"

          line_blocks += Notion::Helpers.callout_blocks(author_line, "💬", context)

          # 📝 Content blocks — centralized extractor ✅
          content_blocks, embed_blocks = Notion::Blocks.extract_blocks(line["content"], page_id, context)

          line_blocks += content_blocks if content_blocks.any?
          line_blocks += embed_blocks if embed_blocks.any?

          # ✅ Sanitize per line
          line_blocks = Notion::Sanitization.sanitize_blocks(line_blocks, context: context)

          # Divider
          line_blocks << Notion::Helpers.divider_block

          blocks.concat(line_blocks)

          # ✅ Progress: mark item complete
          progress.complete_item(line["id"], project["id"], "chat")
        end

        blocks
      end
    end
  end
end
