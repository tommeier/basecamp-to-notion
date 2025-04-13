# /database/schema.rb

require 'sqlite3'
require_relative './config'

def setup_database
  db = SQLite3::Database.new(DB_FILE)

  db.execute_batch <<~SQL
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS projects (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      basecamp_id TEXT UNIQUE,
      notion_page_id TEXT,
      name TEXT,
      status TEXT DEFAULT 'pending',
      last_synced_at DATETIME
    );

    CREATE TABLE IF NOT EXISTS tools (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_basecamp_id TEXT,
      tool_name TEXT,
      status TEXT DEFAULT 'pending',
      last_synced_at DATETIME,
      UNIQUE(project_basecamp_id, tool_name)
    );

    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      basecamp_id TEXT,
      project_basecamp_id TEXT,
      tool_name TEXT,
      notion_page_id TEXT,
      status TEXT DEFAULT 'pending',
      last_synced_at DATETIME,
      UNIQUE(basecamp_id, project_basecamp_id, tool_name)
    );
  SQL

  puts "✅ Database schema is set up!"
end

setup_database
