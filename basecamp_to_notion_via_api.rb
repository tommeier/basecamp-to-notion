#!/usr/bin/env ruby

require_relative "./utils/dependencies"
require_relative "./utils/ensure_gems"
require_relative "./config"
require_relative "./basecamp/auth"
require_relative "./basecamp/fetch"
require_relative "./notion/sync"
require_relative "./utils/cleanup"
require_relative "./utils/logging"
require_relative "./utils/chromedriver_setup"
require_relative "./utils/basecamp_session"
require_relative "./database/schema" # ✅ Ensure schema is initialized

require 'zip'
require 'fileutils'

Utils::Logging.log "🚀 Starting Basecamp → Notion sync..."

Utils::Dependencies.ensure_imagemagick   # makes `identify` available or logs a warning

Utils::ChromedriverSetup.ensure_driver_available
Utils::BasecampSession.ensure_cookies!

# === ✅ Global shutdown flag ===
$shutdown = false

# === ✅ Setup cleanup function for debug files ===
cleanup_debug_files = proc do
  Utils::Logging.flush_log_summary

  timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
  zipfile = "./tmp/debug_#{timestamp}.zip"

  files_to_zip = Dir.glob('./tmp/**/*').reject { |f| File.directory?(f) }

  if files_to_zip.empty?
    Utils::Logging.warn "No debug files found to zip."
  else
    Utils::Logging.debug "🗂️ Zipping up debug files from ./tmp/..."

    Zip::File.open(zipfile, Zip::File::CREATE) do |zipfile_out|
      files_to_zip.each do |file|
        entry_name = file.sub('./tmp/', '').sub('/tmp/', 'tmp/')
        zipfile_out.add(entry_name, file)
      end
    end

    Utils::Logging.log "✅ Debug files zipped to #{zipfile}"
  end
end

# === ✅ Signal handling: set shutdown flag only ===
Signal.trap("INT") do
  Utils::Logging.log "🛑 Interrupt received (Ctrl+C). Initiating shutdown..."
  $shutdown = true
  exit 130 # 128 + SIGINT
end

Signal.trap("TERM") do
  Utils::Logging.log "🛑 Termination signal received (SIGTERM). Initiating shutdown..."
  $shutdown = true
  exit 143 # 128 + SIGTERM
end

# === ✅ At exit cleanup ===
at_exit do
  cleanup_debug_files.call

  if $shutdown
    Utils::Logging.log "🛑 Shutdown complete. Sync interrupted by user."
  else
    Utils::Logging.log "✅ Sync completed successfully."
  end
end

# === ✅ RESET mode: full fresh start ===
if ENV["RESET"] == "true"
  Utils::Logging.warn "RESET mode enabled! Deleting progress DB and temp files for fresh start..."

  if File.exist?(DB_PATH)
    File.delete(DB_PATH)
    Utils::Logging.log "🧹 Deleted progress DB: #{DB_PATH}"
  else
    Utils::Logging.log "ℹ️ No progress DB found. Skipping."
  end

  if Dir.exist?("./tmp")
    FileUtils.rm_rf(Dir["./tmp/*"])
    Utils::Logging.log "🧹 Cleared ./tmp/ debug files."
  else
    Utils::Logging.log "ℹ️ No ./tmp/ directory found. Skipping."
  end

  # This clears cached login
  # if Dir.exist?("./cache")
  #   FileUtils.rm_rf(Dir["./cache/*"])
  #   puts "🧹 Cleared ./cache/ files."
  # else
  #   puts "ℹ️ No ./cache/ directory found. Skipping."
  # end

  Utils::Logging.log "✅ Reset complete. Starting fresh sync."
end

# === ✅ Ensure database schema exists before starting parallel threads ===
setup_database

# === ✅ Start cleanup of old temp files
Cleanup.run

# === ✅ Ensure NOTION_API_KEY is set for official API usage ===
unless ENV['NOTION_API_KEY'] && !ENV['NOTION_API_KEY'].empty?
  Utils::Logging.error "NOTION_API_KEY environment variable is not set. Please set it in your .env file with your Notion integration token."
  exit 1
end
Utils::Logging.log "✅ NOTION_API_KEY found."

require_relative './utils/media_extractor/resolver'

Utils::MediaExtractor::Resolver.ensure_sessions_at_startup!

# === ✅ Run main sync
begin
  Notion::Sync.sync_projects
rescue Interrupt
  Utils::Logging.warn "Sync interrupted by user."
rescue => e
  Utils::Logging.error "Unhandled error: #{e.message}"
  Utils::Logging.error "Backtrace:\n#{e.backtrace.join("\n")}"
  exit 1
end

Utils::Logging.log "🎉 Sync complete!"
