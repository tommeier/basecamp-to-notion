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

    # Finds a child page by its exact title under a given parent page ID.
    # Handles pagination from the Notion API.
    # Returns the page ID if found, or nil otherwise.
    def self.find_child_page_by_title(parent_page_id, title_to_find, context: nil)
      log_ctx = "[Notion::Pages.find_child_page_by_title] Context: #{context || 'N/A'}"
      log "#{log_ctx} Searching for child page with title '#{title_to_find}' under parent '#{parent_page_id}'"

      formatted_parent_id = Notion::Utils.format_uuid(parent_page_id, context: "#{log_ctx} parent_id_formatting")
      return nil unless formatted_parent_id

      start_cursor = nil
      loop do
        uri_string = "https://api.notion.com/v1/blocks/#{formatted_parent_id}/children"
        uri_string += "?start_cursor=#{start_cursor}" if start_cursor
        uri = URI(uri_string)

        response = Notion::API.get_json(uri, Notion::API.default_headers, context: "#{log_ctx} get_children")

        unless response && response['results'].is_a?(Array)
          warn "#{log_ctx} ⚠️ Failed to fetch or parse children for parent '#{formatted_parent_id}'. Response: #{response.inspect}"
          return nil # Or raise an error, depending on desired strictness
        end

        response['results'].each do |block|
          if block['type'] == 'child_page' && block.dig('child_page', 'title') == title_to_find
            found_page_id = block['id']
            log "#{log_ctx} ✅ Found existing child page with title '#{title_to_find}'. ID: #{found_page_id}"
            return Notion::Utils.format_uuid(found_page_id, context: "#{log_ctx} found_page_id_formatting")
          end
        end

        if response['has_more'] && response['next_cursor']
          start_cursor = response['next_cursor']
          log "#{log_ctx} Fetching next page of children (cursor: #{start_cursor}) for parent '#{formatted_parent_id}'"
        else
          break # No more results
        end
      end

      log "#{log_ctx} 🚫 No child page found with title '#{title_to_find}' under parent '#{formatted_parent_id}' after checking all children."
      nil # Not found
    rescue StandardError => e
      error "#{log_ctx} ❌ Error while searching for child page: #{e.message}\n#{e.backtrace.join("\n")}"
      nil # Return nil on error to allow potential creation flow
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

      if source_url && source_url.strip != ''
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

      if rich_text.empty?
        rich_text << {
          type: "text",
          text: {
            content: "Migrated from Basecamp — source unavailable"
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
