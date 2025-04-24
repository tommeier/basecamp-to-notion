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

      # Archive status
      is_archived = project["status"] == "archived"

      # Fetch full project details for metadata
      details = {}
      begin
        details = Basecamp::Fetch.load_json(URI(project["url"]), headers) || {}
      rescue => e
        warn "⚠️ Could not fetch project details: #{e.message}"
      end

      # Count people with access
      people_count = 0
      begin
        people = Basecamp::Fetch.load_json(
          URI(project["url"].sub(/\.json$/, "/people.json")),
          headers
        )
        people_count = people.size if people.is_a?(Array)
      rescue => e
        warn "⚠️ Could not fetch people for project #{project['id']}: #{e.message}"
      end

      # Build project name with icons
      project_name = project["name"].dup
      project_name.prepend("📦 ") if is_archived
      project_name.prepend("🔒 ") if people_count < 50

      existing_project = progress.get_project(project["id"])
      if existing_project && existing_project["notion_page_id"]
        project_page_id = existing_project["notion_page_id"]
        log "🧭 Reusing existing Notion project page: #{project_page_id} for '#{project_name}'"
      else
        raise Interrupt, "Shutdown before project creation" if $shutdown

        log "🆕 Creating Notion page for project: #{project_name}"
        project_page = Notion::Pages.create_page(
          project.merge("name" => project_name, "archived" => is_archived),
          notion_root_page_id,
          children: []
        )
        project_page_id = project_page&.dig("id")

        unless project_page_id
          raise "🚨 project_page_id is nil! Something is wrong."
        end

        # Append metadata toggle block immediately after page
        meta_block = Notion::Helpers.project_metadata_toggle_block(
          project_url:    project["url"],
          people_count:   people_count,
          additional_info: {
            "Created at" => details["created_at"],
            "Purpose"    => details["purpose"]
          }
        )
        Notion::Blocks.append(
          project_page_id,
          [meta_block],
          context: "#{project_name} — Metadata Toggle"
        )

        progress.upsert_project(
          basecamp_id:      project["id"],
          name:             project_name,
          notion_page_id:   project_page_id
        )
      end

      $global_project_count += 1
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

              handler.call(project, tool, tool_page_id, headers, progress) || []

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
        log "🛑 Global shutdown detected before final block. Skipping."
        return
      end

      duration = Time.now - project_start_time
      log "⏱️ Project '#{project_name}' completed in #{duration.round(2)}s"
    end
  end
end
