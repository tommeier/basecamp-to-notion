#!/usr/bin/env ruby

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

puts "🚀 Starting Basecamp → Notion sync..."
Utils::ChromedriverSetup.ensure_driver_available
Utils::BasecampSession.ensure_cookies!

# === ✅ Global shutdown flag ===
$shutdown = false

# === ✅ Setup cleanup function for debug files ===
cleanup_debug_files = proc do
  include Utils::Logging

  if defined?(flush_log_summary)
    flush_log_summary
  end

  timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
  zipfile = "./tmp/debug_#{timestamp}.zip"

  files_to_zip = Dir.glob('./tmp/**/*').reject { |f| File.directory?(f) }

  if files_to_zip.empty?
    puts "⚠️ No debug files found to zip."
  else
    puts "🗂️ Zipping up debug files from ./tmp/..."

    Zip::File.open(zipfile, Zip::File::CREATE) do |zipfile_out|
      files_to_zip.each do |file|
        entry_name = file.sub('./tmp/', '').sub('/tmp/', 'tmp/')
        zipfile_out.add(entry_name, file)
      end
    end

    puts "✅ Debug files zipped to #{zipfile}"
    log "✅ Debug files zipped to #{zipfile}"
  end
end

# === ✅ Signal handling: set shutdown flag only ===
Signal.trap("INT") do
  puts "\n🛑 Interrupt received (Ctrl+C). Initiating shutdown..."
  $shutdown = true
  exit 130 # 128 + SIGINT
end

Signal.trap("TERM") do
  puts "\n🛑 Termination signal received (SIGTERM). Initiating shutdown..."
  $shutdown = true
  exit 143 # 128 + SIGTERM
end

# === ✅ At exit cleanup ===
at_exit do
  cleanup_debug_files.call

  if $shutdown
    puts "\n🛑 Shutdown complete. Sync interrupted by user."
  else
    puts "\n✅ Sync completed successfully."
  end
end

# === ✅ RESET mode: full fresh start ===
if ENV["RESET"] == "true"
  puts "🚨 RESET mode enabled! Deleting progress DB and temp files for fresh start..."

  if File.exist?(DB_PATH)
    File.delete(DB_PATH)
    puts "🧹 Deleted progress DB: #{DB_PATH}"
  else
    puts "ℹ️ No progress DB found. Skipping."
  end

  if Dir.exist?("./tmp")
    FileUtils.rm_rf(Dir["./tmp/*"])
    puts "🧹 Cleared ./tmp/ debug files."
  else
    puts "ℹ️ No ./tmp/ directory found. Skipping."
  end

  # This clears cached login
  # if Dir.exist?("./cache")
  #   FileUtils.rm_rf(Dir["./cache/*"])
  #   puts "🧹 Cleared ./cache/ files."
  # else
  #   puts "ℹ️ No ./cache/ directory found. Skipping."
  # end

  puts "✅ Reset complete. Starting fresh sync."
end

# === ✅ Ensure database schema exists before starting parallel threads ===
setup_database

# === ✅ Start cleanup of old temp files
Cleanup.run

# === ✅ Run main sync
begin
  Notion::Sync.sync_projects
rescue Interrupt
  puts "🛑 Sync interrupted by user."
rescue => e
  puts "❌ Unhandled error: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end

puts "🎉 Sync complete!"
