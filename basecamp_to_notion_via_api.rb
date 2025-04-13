#!/usr/bin/env ruby

require_relative "./config"
require_relative "./basecamp/auth"
require_relative "./basecamp/fetch"
require_relative "./notion/sync"
require_relative "./utils/cleanup"
require_relative "./utils/logging"

require 'zip'

puts "🚀 Starting Basecamp → Notion sync..."

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
