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

    MAX_PROJECT_THREADS = ENV.fetch("MAX_PROJECT_THREADS", "4").to_i

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
      log "  EXCLUDE_PROJECT_LABEL = #{EXCLUDE_PROJECT_LABEL.inspect}"
      log "  FILTER_TOOL_NAME = #{FILTER_TOOL_NAME.inspect}"
      log "  INCLUDE_ARCHIVED = #{ENV["INCLUDE_ARCHIVED"] == "true"}"
      log "  RESET = #{ENV["RESET"] == "true"}"
      log "  CACHE_ENABLED = #{CACHE_ENABLED}"
      log "  MAX_PROJECT_THREADS = #{MAX_PROJECT_THREADS}"

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

      matched_projects = projects
      matched_projects = matched_projects.select { |p| p["name"] =~ /#{FILTER_PROJECT_LABEL}/i } if FILTER_PROJECT_LABEL && !FILTER_PROJECT_LABEL.empty?
      matched_projects = matched_projects.reject { |p| p["name"] =~ /#{EXCLUDE_PROJECT_LABEL}/i } if EXCLUDE_PROJECT_LABEL && !EXCLUDE_PROJECT_LABEL.empty?

      if matched_projects.empty?
        log "⚠️ No projects left after applying filters. FILTER_PROJECT_LABEL=#{FILTER_PROJECT_LABEL.inspect}, EXCLUDE_PROJECT_LABEL=#{EXCLUDE_PROJECT_LABEL.inspect}"
        return
      end

      log "🚀 Starting sync for #{matched_projects.size} matched project(s)..."

      # ✅ Thread pool with safe concurrency
      semaphore = Mutex.new
      queue = Queue.new
      matched_projects.each_with_index { |proj, idx| queue << [proj, idx] }

      threads = Array.new(MAX_PROJECT_THREADS) do
        Thread.new do
          while !queue.empty? && (item = queue.pop(true) rescue nil)
            proj, idx = item
            next unless proj

            begin
              log "\n📁 === [#{idx + 1}/#{matched_projects.size}] Syncing: #{proj['name']} ==="
              start_time = Time.now

              Notion::Process.process_project(proj, NOTION_ROOT_PAGE_ID, headers, progress)

              duration = Time.now - start_time
              log "✅ Finished project '#{proj['name']}' in #{duration.round(2)}s"
            rescue Interrupt
              log "🛑 Project thread interrupted for project '#{proj['name']}'."
              Thread.exit
            rescue => e
              error "❌ Error syncing project '#{proj['name']}': #{e.message}"
              error e.backtrace.join("\n")
              Thread.exit
            end
          end
        end
      end

      # ✅ Optionally log active thread count
      Thread.new do
        loop do
          sleep 5
          alive = threads.count(&:alive?)
          log "🧩 Project thread pool: #{alive} threads active"
          break if threads.all? { |t| !t.alive? }
        end
      end

      threads.each(&:join)

      log "🎉 Project-level sync complete!"

      # ✅ Export progress database at end
      progress.export_dump
      log "✅ Progress database exported."

      log "🧩 All done!"
    end
  end
end
