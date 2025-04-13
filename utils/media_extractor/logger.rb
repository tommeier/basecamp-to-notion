# utils/media_extractor/logger.rb

require_relative '../logging'

module Utils
  module MediaExtractor
    module Logger
      extend ::Utils::Logging

      def self.debug_chunk_summary(chunks, context:, label:)
        debug "🧩 [#{label}] Chunk summary (#{context}): total #{chunks.size} chunks"
        chunks.each_with_index do |chunk, idx|
          length = chunk.sum { |seg| seg.dig(:text, :content).to_s.length }
          debug "    [#{label} Chunk #{idx + 1}] Segments: #{chunk.size}, Total chars: #{length}"
        end
      end

      def self.debug_segment_summary(segment, context:, label:)
        return unless segment
        content = segment.dig(:text, :content).to_s
        length = content.length
        preview = content[0..60]
        debug "    [#{label}] Segment length: #{length} | Preview: '#{preview}' (#{context})"
      end
    end
  end
end
