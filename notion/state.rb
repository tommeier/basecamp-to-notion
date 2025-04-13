# /notion/state.rb

module Notion
  module State
    # ✅ Global counters
    $global_project_count = 0
    $global_tool_count = 0
    $global_block_count = 0
    $global_media_count = 0
    $global_manual_upload_files = []
    $global_start_time = Time.now
  end
end
