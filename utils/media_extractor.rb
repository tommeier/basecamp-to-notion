# utils/media_extractor.rb
#
require 'uri'
require 'open-uri'
require 'net/http'
require 'fileutils'
require 'set'
require 'nokogiri'

# 🔗 Dependencies
require_relative './logging'
require_relative './file_reporter'

# 🧩 Internal Modular Requires (Order matters)
require_relative './media_extractor/constants'
require_relative './media_extractor/logger'
require_relative './media_extractor/helpers'
require_relative './media_extractor/resolver'
require_relative './media_extractor/handlers'
require_relative './media_extractor/rich_text'

module Utils
  module MediaExtractor
    extend ::Utils::Logging
    extend ::Utils::MediaExtractor::Helpers

    class << self
      attr_accessor :basecamp_headers
    end

    @logged_manual_uploads = Set.new

    # ✅ Core entry point: given raw HTML/text, produce notion_blocks and embed_blocks
    def self.extract_and_clean(text, parent_page_id = nil, context = nil)
      return [[], [], []] if text.nil? || text.strip.empty?

      notion_blocks = []
      embed_blocks = []

      doc = Nokogiri::HTML::DocumentFragment.parse(text)
      debug "📦 [extract_and_clean] Starting (#{context}) — nodes: #{doc.children.size}"

      # ✅ Recursive node traversal for safe block handling
      doc.traverse do |node|
        next unless node.element?

        ::Utils::MediaExtractor::Handlers.handle_node_recursive(
          node,
          context,
          parent_page_id,
          notion_blocks,
          embed_blocks
        )
      end

      # ✅ Fallback for plain text that wasn't parsed as nodes
      if notion_blocks.empty? && embed_blocks.empty? && !text.to_s.strip.empty?
        warn "⚠️ [extract_and_clean] No HTML nodes found, using fallback plain text block (#{context})"
        notion_blocks << Helpers.fallback_paragraph_block(text)
      end

      debug "📦 [extract_and_clean] Completed (#{context}): notion_blocks=#{notion_blocks.size}, embed_blocks=#{embed_blocks.size}"

      [
        notion_blocks.compact,
        [], # (media files list, not used)
        embed_blocks.compact
      ]
    end
  end
end
