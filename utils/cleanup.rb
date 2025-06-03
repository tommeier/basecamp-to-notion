# /utils/cleanup.rb

require 'fileutils'
require_relative './media_extractor'
require_relative './logging'

module Cleanup
  DIRS_TO_CLEAN = ['./tmp']
  # './cache' - stores auth

  def self.run
    Utils::Logging.log "🧹 Cleanup: Starting clean of generated directories..."

    DIRS_TO_CLEAN.each do |dir|
      if Dir.exist?(dir)
        Utils::Logging.log "🧹 Cleaning directory: #{dir}"
        FileUtils.rm_rf(Dir.glob("#{dir}/*"))
      else
        Utils::Logging.log "🧹 Creating missing directory: #{dir}"
        FileUtils.mkdir_p(dir)
      end
    end

    Utils::MediaExtractor::Helpers.clear_local_directory

    Utils::Logging.log "✅ Cleanup complete."
  end
end
