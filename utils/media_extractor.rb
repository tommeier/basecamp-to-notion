# utils/media_extractor.rb
#
require 'uri'
require 'open-uri'
require 'net/http'
require 'fileutils'
require 'set'
require 'nokogiri'

# Dependencies
require_relative './logging'
require_relative './file_reporter'

# Internal Modular Requires (Order matters)
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

    # Define known block-level tags that have specific handlers or should break inline groups
    BLOCK_TAG_NAMES = %w[div p ul ol figure h1 h2 h3 blockquote pre hr iframe li img].freeze

    @logged_manual_uploads = Set.new

    # Core entry point: given raw HTML/text, produce notion_blocks and embed_blocks
    def self.extract_and_clean(text, parent_page_id = nil, context = nil)
      return [[], [], []] if text.nil? || text.strip.empty?

      notion_blocks = []
      embed_blocks = [] # Note: embed_blocks are populated within handle_node_recursive
      failed_attachments_details = [] # To collect details of attachments that failed processing
      current_inline_group = []

      doc = Nokogiri::HTML::DocumentFragment.parse(text)
      debug " [extract_and_clean] Starting (#{context}) — top-level nodes: #{doc.children.size}"

      doc.children.each do |node|
        if is_block_node?(node)
          # Process any pending inline nodes before handling the block node
          process_inline_group_into_paragraphs(current_inline_group, notion_blocks, context)
          current_inline_group = [] # Reset the group

          # Delegate the block node to the recursive handler
          debug " [extract_and_clean] Handling block node: <#{node.name}> (#{context})"
          ::Utils::MediaExtractor::Handlers.handle_node_recursive(
            node,
            context,
            parent_page_id,
            notion_blocks, # Pass arrays to be populated
            embed_blocks,
            failed_attachments_details # Add missing argument
          )
        else
          # Add inline or text node to the current group
          current_inline_group << node
        end
      end

      # Process any remaining inline nodes after the loop
      process_inline_group_into_paragraphs(current_inline_group, notion_blocks, context)

      # Fallback if absolutely nothing was generated (highly unlikely now)
      if notion_blocks.empty? && embed_blocks.empty? && !text.to_s.strip.empty?
        warn " [extract_and_clean] No blocks generated after processing, using fallback plain text block (#{context})"
        notion_blocks << Helpers.fallback_paragraph_block(text)
      end

      debug " [extract_and_clean] Completed (#{context}): notion_blocks=#{notion_blocks.size}, embed_blocks=#{embed_blocks.size}"

      [
        notion_blocks.compact,
        [], # (media files list, not used)
        embed_blocks.compact
      ]
    end

    private

    # Helper to check if a node is a recognized block-level element
    def self.is_block_node?(node)
      node.element? && BLOCK_TAG_NAMES.include?(node.name.downcase)
    end

    # Helper to process a group of inline/text nodes into paragraph blocks
    def self.process_inline_group_into_paragraphs(group, notion_blocks, context)
      return if group.empty?

      debug " [extract_and_clean] Processing inline group of #{group.size} nodes (#{context})"
      # Create a temporary fragment containing only the inline nodes
      inline_html = group.map(&:to_html).join
      inline_fragment = Nokogiri::HTML::DocumentFragment.parse(inline_html)

      # Use RichText extractor to handle formatting within the inline group
      rich_text_spans = Utils::MediaExtractor::RichText.extract_rich_text_from_fragment(inline_fragment, context)

      if rich_text_spans.empty?
        debug " [extract_and_clean] Inline group resulted in empty rich text spans (#{context})"
        return
      end

      # Chunk the rich text and create paragraph blocks
      paragraph_blocks = Helpers.chunk_rich_text(rich_text_spans).map do |chunk|
        {
          object: 'block',
          type: 'paragraph',
          paragraph: { rich_text: chunk }
        }
      end

      debug " [extract_and_clean] Generated #{paragraph_blocks.size} paragraph blocks from inline group (#{context})"
      notion_blocks.concat(paragraph_blocks)
    end
  end
end
