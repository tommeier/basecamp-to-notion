require 'fileutils'

module Utils
  module Logging
    LOG_FILE_PATH = "./tmp/basecamp_to_notion_debug.log"
    LOG_FILE_DIR = File.dirname(LOG_FILE_PATH)

    # Ensure log file directory exists at load time
    FileUtils.mkdir_p(LOG_FILE_DIR)

    def log(message)
      formatted = format_log(message)
      puts formatted
      append_to_log_file(formatted)
    end

    def error(message)
      formatted = format_log("❌ ERROR: #{message}")
      STDERR.puts formatted
      append_to_log_file(formatted)
    end

    def warn(message)
      formatted = format_log("⚠️ WARNING: #{message}")
      STDERR.puts formatted
      append_to_log_file(formatted)
    end

    def debug(message)
      return unless ENV['DEBUG'] == 'true'
      formatted = format_log("🐛 DEBUG: #{message}")
      puts formatted
      append_to_log_file(formatted)
    end

    def debug_file(content, path: "./tmp/debug.log")
      return unless defined?(DEBUG_FILES) && DEBUG_FILES
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(content) }
      puts "📝 Debug file written to: #{path}"
      append_to_log_file("📝 Debug file written to: #{path}")
    end

    def flush_log_summary
      final_message = format_log("✅ Log session completed at #{current_timestamp}")
      append_to_log_file(final_message)
    end

    private

    def current_timestamp
      Time.now.strftime("%Y-%m-%d %H:%M:%S")
    end

    def format_log(message)
      "[#{current_timestamp}] #{message}"
    end

    def append_to_log_file(message)
      File.open(LOG_FILE_PATH, "a") { |f| f.puts(message) }
    rescue => e
      STDERR.puts "[#{current_timestamp}] ⚠️ Failed to write to log file: #{e.message}"
    end
  end
end
