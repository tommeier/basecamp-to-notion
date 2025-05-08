# /config.rb

require 'dotenv/load'

# === BASECAMP CONFIG ===
BASECAMP_CLIENT_ID     = ENV.fetch("BASECAMP_CLIENT_ID")
BASECAMP_CLIENT_SECRET = ENV.fetch("BASECAMP_CLIENT_SECRET")
BASECAMP_REDIRECT_URI  = ENV.fetch("BASECAMP_REDIRECT_URI")
BASECAMP_ACCOUNT_ID    = ENV.fetch("BASECAMP_ACCOUNT_ID")

# === NOTION CONFIG ===
NOTION_API_KEY         = ENV.fetch("NOTION_API_KEY")
NOTION_ROOT_PAGE_ID    = ENV.fetch("NOTION_ROOT_PAGE_ID")
# token_v2 might be set later after browser auth; fetch lazily where needed
NOTION_TOKEN_V2       = ENV["NOTION_TOKEN_V2"]

# === FILTERS (Optional) ===
FILTER_PROJECT_LABEL   = ENV.fetch("FILTER_PROJECT_LABEL", nil)
EXCLUDE_PROJECT_LABEL  = ENV.fetch("EXCLUDE_PROJECT_LABEL", nil)
FILTER_TOOL_NAME       = ENV.fetch("FILTER_TOOL_NAME", nil)

# === RUNTIME FLAGS ===
CACHE_ENABLED          = ENV.fetch("CACHE_ENABLED", "false") == "true"

# === OTHER CONFIG ===
CACHE_DIR              = "./cache"
DB_PATH                = "./sync_progress.db"
BACKOFF_BASE           = 2

# === BATCHING CONFIG ===
MAX_NOTION_PAYLOAD_BYTES = 700_000
MAX_NOTION_BLOCKS_PER_BATCH = 100
MAX_CHILDREN_PER_BLOCK = 50

# === DEBUGGING ===
DEBUG_FILES            = false
