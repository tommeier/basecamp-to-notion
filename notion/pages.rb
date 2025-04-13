# /notion/pages.rb

require_relative "../config"
require_relative "../utils/logging"
require_relative "./api"
require_relative "./utils"
require_relative "./blocks"

module Notion
  module Pages
    extend ::Utils::Logging

    def self.create_page(project, parent_id, children: [], context: nil, url: nil)
      context ||= "Create Page: #{project['name']}"
      if parent_id.nil?
        warn "🚫 create_page: parent_id is nil. Skipping page creation. Context: #{context}"
        return nil
      end

      parent_id = Notion::Utils.format_uuid(parent_id, context: context)

      project_name = project["name"]

      log "🆕 Creating Notion page: #{project_name} under parent: #{parent_id}#{context ? " (#{context})" : ""}"

      payload = {
        parent: { page_id: parent_id },
        properties: {
          title: [
            {
              text: { content: project_name }
            }
          ]
        },
        icon: { emoji: "📁" }
      }

      res = Notion::API.post_json(
        URI("https://api.notion.com/v1/pages"),
        payload,
        Notion::API.default_headers,
        context: context
      )

      page_id = res['id']
      if page_id.nil?
        warn "🚫 create_page: Failed to get page ID from creation response"
        return res
      end

      log "✅ Notion page created: #{page_id}"

      # ✅ Insert migration banner
      banner = migration_banner_block(project, url)
      Notion::Blocks.append(page_id, [banner], context: "#{context} - Migration Banner")
      log "🧩 Inserted migration banner block for page #{page_id}"

      # ✅ Insert archive banner if applicable
      if project["archived"] == true
        archive_notice = {
          object: "block",
          type: "callout",
          callout: {
            icon: { type: "emoji", emoji: "📦" },
            rich_text: [{
              type: "text",
              text: { content: "⚠️ This project was archived in Basecamp." }
            }],
            color: "yellow_background"
          }
        }
        Notion::Blocks.append(page_id, [archive_notice], context: "#{context} - Archive Notice")
        log "🧩 Inserted archive notice block for page #{page_id}"
      end

      # ✅ Append children if provided
      unless children.empty?
        log "🧩 Appending initial children to page #{page_id} (#{children.size} blocks)"
        Notion::Blocks.append(page_id, children, context: "#{context} - Initial Children")
      end

      res
    end

    def self.migration_banner_block(project, url = nil)
      source_url = url || project["url"]
      timestamp = Time.now.utc.strftime("%d/%m/%Y at %H:%M UTC")

      rich_text = [
        {
          type: "text",
          text: {
            content: "Migrated from Basecamp on #{timestamp} — 🔗 "
          }
        }
      ]

      if source_url
        web_url = source_url
          .gsub('basecampapi.com', 'basecamp.com')
          .gsub(/\.json$/, '')

        rich_text << {
          type: "text",
          text: {
            content: web_url,
            link: { url: web_url }
          }
        }
      end

      {
        object: "block",
        type: "callout",
        callout: {
          icon: { type: "emoji", emoji: "🏕️" },
          rich_text: rich_text,
          color: "yellow_background"
        }
      }
    end
  end
end
