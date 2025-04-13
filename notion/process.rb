# /notion/process.rb

require_relative '../config'
require_relative './blocks'
require_relative './constants'
require_relative './helpers'
require_relative './pages'
require_relative './state'
require_relative './utils'
require_relative '../utils/file_reporter'
require_relative '../utils/logging'
require_relative '../utils/media_extractor'

module Notion
  module Process
    extend ::Utils::Logging

    def self.process_project(project, notion_root_page_id, headers, progress)
      log "🧱 Processing project: #{project['name']} (#{project['id']})"

      project_start_time = Time.now
      project_page_id = nil

      # ✅ Detect archive status early
      is_archived = project["status"] == "archived"
      project_name = is_archived ? "📦 #{project["name"]}" : project["name"]

      existing_project = progress.get_project(project["id"])
      if existing_project && existing_project["notion_page_id"]
        project_page_id = existing_project["notion_page_id"]
        log "🧭 Reusing existing Notion project page: #{project_page_id} for '#{project_name}'"
      else
        raise Interrupt, "Shutdown before project creation" if $shutdown

        log "🆕 Creating Notion page for project: #{project_name}"
        project_page = Notion::Pages.create_page(project.merge("name" => project_name, "archived" => is_archived), notion_root_page_id, children: [])
        project_page_id = project_page["id"]

        unless project_page_id
          raise "🚨 project_page_id is nil! Something is wrong."
        end

        progress.upsert_project(
          basecamp_id: project["id"],
          name: project_name,
          notion_page_id: project_page_id
        )
      end

      $global_project_count += 1

      index_items = []
      tool_block_counts = {}
      total_blocks = 0

      tools = (project["dock"] || [])

      threads = tools.map do |tool|
        Thread.new do
          begin
            if $shutdown
              log "🛑 Shutdown detected before starting tool '#{tool['name']}'. Exiting thread."
              Thread.exit
            end

            name = tool["name"]
            log "🧩 [#{name}] Starting tool sync..."

            if FILTER_TOOL_NAME && name != FILTER_TOOL_NAME
              log "🚫 [#{name}] Skipping tool due to FILTER_TOOL_NAME=#{FILTER_TOOL_NAME}"
              Thread.exit
            end

            title = tool["title"] || name.capitalize
            handler = TOOL_HANDLERS[name]
            emoji = TOOL_EMOJIS.fetch(name, TOOL_EMOJIS["default"])

            progress.upsert_tool(
              project_basecamp_id: project["id"],
              tool_name: name
            )

            if handler
              log "🔧 [#{name}] Handling tool '#{title}' with #{handler}..."

              existing_tool = progress.get_tool(project["id"], name)
              if existing_tool && existing_tool["status"] == 'done'
                log "🧭 [#{name}] Skipping tool — already marked done."
                Thread.exit
              end

              raise Interrupt, "Shutdown before creating tool page" if $shutdown

              tool_page = Notion::Pages.create_page(
                { "name" => "#{emoji} #{title}", "url" => tool["url"] },
                project_page_id,
                children: [],
                context: "#{emoji} #{title} (Tool Page)",
                url: tool["url"]
              )
              tool_page_id = tool_page&.dig("id")

              unless tool_page_id
                error "🚨 [#{name}] Failed to create Notion page for tool '#{title}'. Skipping tool."
                Thread.exit
              end

              raise Interrupt, "Shutdown before handler call" if $shutdown

              blocks = handler.call(project, tool, tool_page_id, headers, progress) || []

              unless blocks.is_a?(Array)
                warn "🚫 [#{name}] Handler did not return an array. Got: #{blocks.inspect}"
                blocks = []
              end

              tool_block_counts[name] = blocks.size
              total_blocks += blocks.size

              if blocks.any?
                if blocks.size > MAX_BLOCKS_PER_TOOL_PAGE
                  log "📝 [#{name}] Splitting tool page into subpages (#{blocks.size} blocks)..."
                  subpages = Notion::Utils.split_blocks_into_subpages(blocks, title, emoji, tool_page_id)

                  subpages.each do |subpage|
                    index_items << Notion::Helpers.index_link_block(subpage[:id], subpage[:title], emoji)
                  end

                  index_items << Notion::Helpers.index_link_block(tool_page_id, "#{emoji} #{title} (Overview)", emoji)
                else
                  Notion::Blocks.append(tool_page_id, blocks, context: "Tool Page: #{emoji} #{title}")
                  index_items << Notion::Helpers.index_link_block(tool_page_id, "#{emoji} #{title}", emoji)
                end

                index_items.compact!
              else
                log "📝 [#{name}] No blocks to append."
              end

              progress.complete_tool(project["id"], name)
              log "✅ [#{name}] Finished tool sync."
            else
              log "📝 [#{name}] Unrecognized dock type: #{tool.inspect}"
              log "✅ [#{name}] Finished tool sync."
            end
          rescue Interrupt
            log "🛑 Thread for tool '#{tool['name']}' interrupted. Exiting thread."
            Thread.exit
          rescue => e
            error "❌ [#{tool['name']}] Unhandled error: #{e.message}"
            error e.backtrace.join("\n")
            Thread.exit
          end
        end
      end

      threads.each(&:join)

      if $shutdown
        log "🛑 Global shutdown detected before final index append. Skipping index block creation."
        return
      end

      if index_items.any?
        index_blocks = [
          Notion::Helpers.heading_block("🗂️ Index", 2, "Index"),
          Notion::Helpers.divider_block,
          Notion::Helpers.callout_block("Quick Links to Tools", "🚀", "Index"),
          Notion::Helpers.divider_block
        ] + index_items + [Notion::Helpers.divider_block]

        Notion::Blocks.append(project_page_id, index_blocks, context: "Index Page")
      else
        log "📝 No tools processed, skipping index block"
      end

      if tool_block_counts.any?
        summary = tool_block_counts.map { |tool, count| "#{tool}=#{count} blocks" }.join(", ")
        log "🗂️ Tool summary: #{summary}"
      end

      duration = Time.now - project_start_time
      log "⏱️ Project '#{project_name}' completed in #{duration.round(2)}s"
    end
  end
end
