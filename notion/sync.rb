# /notion/sync.rb

require_relative '../config'
require_relative '../basecamp/auth'
require_relative '../basecamp/fetch'
require_relative '../database/progress_tracker'
require_relative '../utils/logging'
require_relative '../utils/media_extractor'
require_relative './state'
require_relative './helpers'
require_relative './pages'
require_relative './process'

module Notion
  module Sync
    extend ::Utils::Logging

    def self.sync_projects
      log "🔄 Fetching Basecamp token..."
      token = Basecamp::Auth.token
      headers = { "Authorization" => "Bearer #{token}", "User-Agent" => "BasecampToNotionScript" }

      # ✅ Set global MediaExtractor headers
      ::Utils::MediaExtractor.basecamp_headers = headers.freeze

      # ✅ Print runtime config for clarity
      log "🔧 Runtime configuration:"
      log "  BASECAMP_ACCOUNT_ID = #{BASECAMP_ACCOUNT_ID}"
      log "  FILTER_PROJECT_LABEL = #{FILTER_PROJECT_LABEL.inspect}"
      log "  FILTER_TOOL_NAME = #{FILTER_TOOL_NAME.inspect}"
      log "  INCLUDE_ARCHIVED = #{ENV["INCLUDE_ARCHIVED"] == "true"}"
      log "  RESET = #{ENV["RESET"] == "true"}"
      log "  CACHE_ENABLED = #{CACHE_ENABLED}"

      # ✅ Initialize progress tracker
      progress = ProgressTracker.new

      log "🔄 Fetching projects..."
      uri = URI("https://3.basecampapi.com/#{BASECAMP_ACCOUNT_ID}/projects.json")
      log "📥 Fetching active projects..."
      projects = Basecamp::Fetch.load_json(uri, headers)
      log "📦 Active projects fetched: #{projects.size}"

      if ENV["INCLUDE_ARCHIVED"] == "true"
        log "📥 INCLUDE_ARCHIVED=true — fetching archived projects..."
        archived_uri = URI("https://3.basecampapi.com/#{BASECAMP_ACCOUNT_ID}/projects.json?status=archived")
        archived_projects = Basecamp::Fetch.load_json(archived_uri, headers)
        log "📦 Archived projects fetched: #{archived_projects.size}"
        projects.concat(archived_projects)
      end

      log "📦 Total projects fetched (active + archived if enabled): #{projects.size}"

      matched_projects = projects.select { |proj| proj["name"] =~ /#{FILTER_PROJECT_LABEL}/i }

      if matched_projects.empty?
        log "⚠️ No matching projects found with FILTER_PROJECT_LABEL=#{FILTER_PROJECT_LABEL.inspect}"
        return
      end

      log "🚀 Starting sync for #{matched_projects.size} matched project(s)..."

      matched_projects.each_with_index do |proj, idx|
        log "\n📁 === [#{idx + 1}/#{matched_projects.size}] Syncing: #{proj['name']} ==="
        start_time = Time.now

        begin
          Notion::Process.process_project(proj, NOTION_ROOT_PAGE_ID, headers, progress)
        rescue => e
          error "❌ Error syncing project '#{proj['name']}': #{e.message}"
          error e.backtrace.join("\n")
        end

        duration = Time.now - start_time
        log "✅ Finished project '#{proj['name']}' in #{duration.round(2)}s"
      end

      log "🎉 Sync complete!"

      # ✅ Export progress database at end
      progress.export_dump
      log "✅ Progress database exported."

      log "🧩 All done!"
    end
  end
end
