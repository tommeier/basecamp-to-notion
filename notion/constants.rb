# /notion/constants.rb

module Notion
  require_relative './handlers/message_board'
  require_relative './handlers/todoset'
  require_relative './handlers/vault'
  require_relative './handlers/chat'
  require_relative './handlers/schedule'
  require_relative './handlers/questionnaire'
  require_relative './handlers/inbox'
  require_relative './handlers/kanban_board'

  MAX_BLOCKS_PER_REQUEST = 100 # Notion API hard limit
  MAX_NOTION_TEXT_LENGTH = 2000 # Text length safety
  MAX_BLOCKS_PER_TOOL_PAGE = 800 # Safe under Notion hard limit of ~1000
  MAX_BLOCKS_PER_PAGE_CREATION = 100 # Page creation limit (API constraint)

  # 🚨 System-level blocks (always added to new pages)
  # - Migration banner = 1 block
  # - Archive notice (if applicable) = 1 block
  # ✅ Always assume 2 blocks for safety
  SYSTEM_BLOCKS_AT_CREATION = 2

  TOOL_HANDLERS = {
    "message_board" => Notion::Handlers::MessageBoard,
    "todoset" => Notion::Handlers::Todoset,
    "vault" => Notion::Handlers::Vault,
    "chat" => Notion::Handlers::Chat,
    "schedule" => Notion::Handlers::Schedule,
    "questionnaire" => Notion::Handlers::Questionnaire,
    "inbox" => Notion::Handlers::Inbox,
    "kanban_board" => Notion::Handlers::KanbanBoard
  }.freeze

  TOOL_EMOJIS = {
    "message_board" => "📝",
    "todoset" => "✅",
    "vault" => "🔒",
    "chat" => "💬",
    "schedule" => "📅",
    "questionnaire" => "❓",
    "inbox" => "📥",
    "kanban_board" => "🗂️",
    "default" => "📁"
  }.freeze
end
