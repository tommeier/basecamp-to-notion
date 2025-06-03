# utils/block_validator.rb

require_relative './logging'

module BlockValidator
  def self.validate_blocks(blocks, context = nil)
    valid = 0
    invalid = 0

    (blocks || []).each_with_index do |block, idx|
      if valid_block?(block)
        valid += 1
      else
        invalid += 1
        Utils::Logging.warn "Invalid block at index #{idx}#{context ? " (#{context})" : ""}: #{block.inspect[0..500]}"
      end

      if block.is_a?(Hash) && block['children']
        child_valid, child_invalid = validate_blocks(block['children'], "#{context} > children[#{idx}]")
        valid += child_valid
        invalid += child_invalid
      end
    end

    Utils::Logging.log "🧩 Block validation summary#{context ? " (#{context})" : ""}: ✅ #{valid} valid / 🚫 #{invalid} invalid"
    [valid, invalid]
  end

  def self.valid_block?(block)
    block.is_a?(Hash) && block.key?("type")
  end
end
