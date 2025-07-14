require 'fileutils'

module Utils
  module Logging
    LOG_FILE_PATH = "./tmp/basecamp_to_notion_debug.log"
    LOG_FILE_DIR = File.dirname(LOG_FILE_PATH)

    # Ensure log file directory exists at load time
    FileUtils.mkdir_p(LOG_FILE_DIR)

    def self.log(message)
      formatted = format_log(message)
      puts formatted
      append_to_log_file(formatted)
    end

    def self.error(message)
      formatted = format_log("❌ ERROR: #{message}")
      STDERR.puts formatted
      append_to_log_file(formatted)
    end

    def self.warn(message)
      formatted = format_log("⚠️ WARNING: #{message}")
      STDERR.puts formatted
      append_to_log_file(formatted)
    end

    def self.debug(message)
      return unless ENV['DEBUG'] == 'true' || ENV['LOG_LEVEL'] == 'debug'
      formatted = format_log("🐛 DEBUG: #{message}")
      puts formatted
      append_to_log_file(formatted)
    end

    def self.debug_file(content, path: "./tmp/debug.log")
      return unless defined?(DEBUG_FILES) && DEBUG_FILES
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(content) }
      Utils::Logging.log "📝 Debug file written to: #{path}"
    end

    def self.flush_log_summary
      final_message = format_log("✅ Log session completed at #{current_timestamp}")
      append_to_log_file(final_message)
    end

    # ------------------------------------------------------------------
    # Preserve original class-level implementations for internal use
    # ------------------------------------------------------------------
    class << self
      alias_method :_log_class, :log
      alias_method :_error_class, :error
      alias_method :_warn_class, :warn
      alias_method :_debug_class, :debug
      alias_method :_debug_file_class, :debug_file
      alias_method :_flush_log_summary_class, :flush_log_summary
    end

    # ------------------------------------------------------------------
    # Expose logging helpers for modules that `extend Utils::Logging`
    # ------------------------------------------------------------------
    def log(message) = Utils::Logging._log_class(message)
    def error(message) = Utils::Logging._error_class(message)
    def warn(message) = Utils::Logging._warn_class(message)
    def debug(message) = Utils::Logging._debug_class(message)
    def debug_file(content, path: "./tmp/debug.log") = Utils::Logging._debug_file_class(content, path: path)
    def flush_log_summary = Utils::Logging._flush_log_summary_class

    # Delegate instance-style logging helpers remain public so that modules
    # that `extend Utils::Logging` can call them without visibility errors.
    # We deliberately avoid `module_function` here because it would make the
    # instance versions private, which breaks callers like
    # `Utils::MediaExtractor::Logger.error(...)`.

    class << self
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
        # Use self.current_timestamp here as we are in class << self context
        # or ensure current_timestamp is also callable directly if this were a separate private instance method.
        # However, since all these are now private static methods, calling current_timestamp directly works.
        STDERR.puts "[#{current_timestamp}] ⚠️ Failed to write to log file: #{e.message}"
      end
    end
  end
end
