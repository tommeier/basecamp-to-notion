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
# Disable "🔒" and "📦" prefixes on project names when true.
DISABLE_PROJECT_EMOJI_PREFIXES = ENV.fetch('DISABLE_PROJECT_EMOJI_PREFIXES', 'false') == 'true'
CACHE_ENABLED          = ENV.fetch("CACHE_ENABLED", "false") == "true"

# === OTHER CONFIG ===
CACHE_DIR              = "./cache"
DB_PATH                = "./sync_progress.db"
BACKOFF_BASE           = 2

# === BATCHING CONFIG ===
# Max number of blocks per batch request to Notion (API limit is 100, we use a safer default)
NOTION_BATCH_MAX_BLOCKS = ENV.fetch('NOTION_BATCH_MAX_BLOCKS', 50).to_i
# Max payload size in KB for a batch request (Notion API limit is around 1000KB for block appends, we use a safer default)
NOTION_BATCH_MAX_PAYLOAD_KB = ENV.fetch('NOTION_BATCH_MAX_PAYLOAD_KB', 700).to_i
MAX_NOTION_PAYLOAD_BYTES = NOTION_BATCH_MAX_PAYLOAD_KB * 1024

# Max children for a single block's internal structure (used by split_large_blocks)
MAX_CHILDREN_PER_BLOCK = ENV.fetch('NOTION_MAX_CHILDREN_PER_BLOCK', 50).to_i


# === SELENIUM WATCHDOG CONFIG ===
# Number of consecutive Selenium operation failures for the same item (e.g., URL) before attempting a driver restart.
SELENIUM_CONSECUTIVE_OPERATION_FAILURES_THRESHOLD = ENV.fetch('SELENIUM_CONSECUTIVE_OPERATION_FAILURES_THRESHOLD', 3).to_i
# Number of times to attempt restarting the driver for a single problematic operation before giving up on that specific operation.
SELENIUM_RESTARTS_PER_OPERATION_LIMIT = ENV.fetch('SELENIUM_RESTARTS_PER_OPERATION_LIMIT', 1).to_i
# Total number of times the Selenium driver can be restarted globally during the script's run before the script terminates.
SELENIUM_MAX_GLOBAL_RESTARTS = ENV.fetch('SELENIUM_MAX_GLOBAL_RESTARTS', 2).to_i


# === DEBUGGING ===
DEBUG_FILES            = false
