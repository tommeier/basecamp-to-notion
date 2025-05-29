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

  # ✅ Notion hard limits and safety caps
  MAX_BLOCKS_PER_REQUEST = 100 # Notion API hard limit
  MAX_NOTION_TEXT_LENGTH = 2000 # Safety for individual text lengths
  MAX_BLOCKS_PER_TOOL_PAGE = 800 # Safety cap below hard ~1000 limit
  MAX_BLOCKS_PER_PAGE_CREATION = 100 # Page creation limit
  HOSTED_FILE_URL_PREFIX = "https://prod-files-secure.s3".freeze # Prefix for Notion's S3 hosted files

  # ✅ Important: count system-level blocks added at page creation
  # - Migration banner: ✅ 1 block
  # - Archive notice: ✅ 1 block (if applicable)
  # Safe assumption: always reserve space for 2 system blocks
  SYSTEM_BLOCKS_AT_CREATION = 2

  # ✅ Tool handlers map
  TOOL_HANDLERS = {
    "message_board"    => Notion::Handlers::MessageBoard,
    "todoset"          => Notion::Handlers::Todoset,
    "vault"            => Notion::Handlers::Vault,
    "chat"             => Notion::Handlers::Chat,
    "schedule"         => Notion::Handlers::Schedule,
    "questionnaire"    => Notion::Handlers::Questionnaire,
    "inbox"            => Notion::Handlers::Inbox,
    "kanban_board"     => Notion::Handlers::KanbanBoard
  }.freeze

  # ✅ Emoji mapping per tool
  TOOL_EMOJIS = {
    "message_board"    => "📝",
    "todoset"          => "✅",
    "vault"            => "🔒",
    "chat"             => "💬",
    "schedule"         => "📅",
    "questionnaire"    => "❓",
    "inbox"            => "📥",
    "kanban_board"     => "🗂️",
    "default"          => "📁"
  }.freeze
end
