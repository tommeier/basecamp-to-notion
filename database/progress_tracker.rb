# /database/progress_tracker.rb

require 'sqlite3'
require 'time'
require_relative './config'
require_relative './schema'
require_relative '../utils/logging'

DB_CREATED = !File.exist?(DB_FILE)

# Auto-create database if missing
setup_database if DB_CREATED

Utils::Logging.log "🗄️ Progress database: #{DB_FILE}"
Utils::Logging.log(DB_CREATED ? "📦 Created new database at #{DB_FILE}" : "✅ Existing database found, using #{DB_FILE}")

class ProgressTracker
  def initialize
    @db = SQLite3::Database.new(DB_FILE)
    @db.results_as_hash = true
  end

  # --- Project level ---

  def get_project(basecamp_id)
    @db.get_first_row("SELECT * FROM projects WHERE basecamp_id = ?", [basecamp_id])
  end

  def upsert_project(basecamp_id:, name:, notion_page_id: nil, status: 'in_progress')
    now = Time.now.utc.iso8601
    @db.execute <<-SQL, [basecamp_id, name, notion_page_id, status, now, name, notion_page_id, status, now]
      INSERT INTO projects (basecamp_id, name, notion_page_id, status, last_synced_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(basecamp_id) DO UPDATE SET
        name = ?,
        notion_page_id = ?,
        status = ?,
        last_synced_at = ?;
    SQL
  end

  def complete_project(basecamp_id)
    now = Time.now.utc.iso8601
    @db.execute "UPDATE projects SET status = 'done', last_synced_at = ? WHERE basecamp_id = ?", [now, basecamp_id]
  end

  # --- Tool level ---

  def get_tool(project_basecamp_id, tool_name)
    @db.get_first_row("SELECT * FROM tools WHERE project_basecamp_id = ? AND tool_name = ?", [project_basecamp_id, tool_name])
  end

  def upsert_tool(project_basecamp_id:, tool_name:, status: 'in_progress')
    now = Time.now.utc.iso8601
    @db.execute <<-SQL, [project_basecamp_id, tool_name, status, now, status, now]
      INSERT INTO tools (project_basecamp_id, tool_name, status, last_synced_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(project_basecamp_id, tool_name) DO UPDATE SET
        status = ?,
        last_synced_at = ?;
    SQL
  end

  def complete_tool(project_basecamp_id, tool_name)
    now = Time.now.utc.iso8601
    @db.execute "UPDATE tools SET status = 'done', last_synced_at = ? WHERE project_basecamp_id = ? AND tool_name = ?", [now, project_basecamp_id, tool_name]
  end

  # --- Item level ---

  def upsert_item(basecamp_id:, project_basecamp_id:, tool_name:, notion_page_id: nil, status: 'in_progress')
    now = Time.now.utc.iso8601
    @db.execute <<-SQL, [basecamp_id, project_basecamp_id, tool_name, notion_page_id, status, now, notion_page_id, status, now]
      INSERT INTO items (basecamp_id, project_basecamp_id, tool_name, notion_page_id, status, last_synced_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(basecamp_id, project_basecamp_id, tool_name) DO UPDATE SET
        notion_page_id = ?,
        status = ?,
        last_synced_at = ?;
    SQL
  end

  def complete_item(basecamp_id, project_basecamp_id, tool_name)
    now = Time.now.utc.iso8601
    @db.execute "UPDATE items SET status = 'done', last_synced_at = ? WHERE basecamp_id = ? AND project_basecamp_id = ? AND tool_name = ?", [now, basecamp_id, project_basecamp_id, tool_name]
  end

  # --- Reporting ---

  def print_summary
    puts "\n📊 Sync Summary:"
    %w[projects tools items].each do |table|
      counts = @db.execute "SELECT status, COUNT(*) as count FROM #{table} GROUP BY status"
      puts "➡️ #{table.capitalize}:"
      counts.each { |row| puts "   #{row['status']}: #{row['count']}" }
    end
    puts ""
  end

  def export_dump
    dump_file = "sync_progress_#{Time.now.strftime("%Y%m%d-%H%M%S")}.sql"
    `sqlite3 #{DB_FILE} .dump > #{dump_file}`
    Utils::Logging.log "🧩 Progress database exported to: #{dump_file}"
  end
end
