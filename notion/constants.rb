# notion/constants.rb

module Notion
  require_relative './handlers/message_board'
  require_relative './handlers/todoset'
  require_relative './handlers/vault'
  require_relative './handlers/chat'
  require_relative './handlers/schedule'
  require_relative './handlers/questionnaire'
  require_relative './handlers/inbox'
  require_relative './handlers/kanban_board'

  MAX_BLOCKS_PER_REQUEST = 100 # 100 limit
  # Maximum character length for Notion text content
  MAX_NOTION_TEXT_LENGTH = 2000 # 2000-4000 limit
  MAX_BLOCKS_PER_TOOL_PAGE = 800 # 1000 hard limit
  MAX_BLOCKS_PER_PAGE_CREATION = 100 # 100 hard limit
  MIGRATION_BANNER_BLOCKS = 1

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
