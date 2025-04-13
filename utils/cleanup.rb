# /utils/cleanup.rb

require 'fileutils'
require_relative './media_extractor'

module Cleanup
  DIRS_TO_CLEAN = ['./tmp']
  # './cache' - stores auth

  def self.run
    puts "🧹 Cleanup: Starting clean of generated directories..."

    DIRS_TO_CLEAN.each do |dir|
      if Dir.exist?(dir)
        puts "🧹 Cleaning directory: #{dir}"
        FileUtils.rm_rf(Dir.glob("#{dir}/*"))
      else
        puts "🧹 Creating missing directory: #{dir}"
        FileUtils.mkdir_p(dir)
      end
    end

    Utils::MediaExtractor::Helpers.clear_local_directory

    puts "✅ Cleanup complete."
  end
end
