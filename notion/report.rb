require_relative '../config'
require_relative '../utils/logging'

module Notion
  module Report
    def self.final_summary
      total_time = Time.now - $global_start_time
      log "🏁 Sync complete in #{total_time.round(2)}s"
      log "📊 Global summary: Projects: #{$global_project_count}, Tools: #{$global_tool_count}, Blocks: #{$global_block_count}, Media: #{$global_media_count}"
    end
  end
end
