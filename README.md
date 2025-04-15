# 🧩 Basecamp to Notion Migration Script

> Migrate your complete Basecamp workspace to structured, beautiful, fully linked Notion pages.

---

## 🚀 Overview

This Ruby-based CLI tool migrates full Basecamp data into Notion with high fidelity, including:

- ✅ Projects
- ✅ Messages + comments
- ✅ Chats + subpages by year
- ✅ Todosets
- ✅ Vault docs
- ✅ Schedules
- ✅ Inbox forwards
- ✅ Kanban boards
- ✅ Questionnaires
- ✅ Inline images, embeds, media (when external, not internal basecamp assets)
- ✅ Metadata (authors, timestamps, source links)
- ✅ Migration banners ("Migrated from Basecamp on DD/MM/YYYY — Source URL")
- ✅ Smart sub-page splitting for large datasets
- ✅ Progress tracking (projects, tools, individual items)
- ✅ Safe to interrupt and resume ✅
- ✅ Optional filters (per project label, per tool name)

The script is fully idempotent and checkpoint-resumable for large Basecamp accounts (multi-hour runs).

---

## 📦 Features

| Feature | Status |
|---------|---------|
| ✅ Full Basecamp API coverage | Projects, dock tools, comments |
| ✅ Rich Notion formatting | Headings, callouts, checklists, embeds, dividers |
| ✅ Inline media support | Images, attachments, links, external embeds |
| ✅ Progress tracking | Projects, tools, and items (messages, chats, todos...) |
| ✅ Checkpoint resume | Safe re-runs from last progress |
| ✅ Delta sync ready | Track last synced timestamp |
| ✅ Split large tool pages | Automatically chunk by year / batch |
| ✅ Migration banners | Add "Migrated from Basecamp" banner to every page |
| ✅ Final sync report | Per-project, per-tool, per-item status |
| ✅ SQLite progress database | Local file `sync_progress.db` for resume & audit |
| ✅ Debug mode | Detailed logs and payload dumps in `./tmp/` |

---

## ⚙️ Requirements

- Ruby 3.2+
- Basecamp OAuth App credentials (client ID, client secret)
- Notion API integration token and page access

Install Ruby dependencies:

```bash
gem install sqlite3
```

---

## 🧩 Setup

### 1. Prepare Basecamp OAuth App

Basecamp no longer uses Personal Access Tokens.

Instead, create an OAuth app:

1. Go to: [Basecamp OAuth App Registration](https://launchpad.37signals.com/registrations/new)
2. Register a new application:
   - Name: **Basecamp to Notion Migrator**
   - Redirect URI: `http://localhost:4567/callback`
3. After creation, copy:
   - **Client ID** → `BASECAMP_CLIENT_ID`
   - **Client Secret** → `BASECAMP_CLIENT_SECRET`
4. Find your **Basecamp Account ID**:
   - Visit: https://3.basecamp.com/
   - Note the number in the URL: `https://3.basecamp.com/123456789/`

### 2. Prepare Notion Integration

1. Go to: [Notion My Integrations](https://www.notion.so/my-integrations)
2. Create a new integration:
   - Name: **Basecamp to Notion Migrator**
   - Give full permissions:
     - ✅ Insert content
     - ✅ Read content
     - ✅ Update content
3. Copy the **Internal Integration Token** → `NOTION_API_KEY`
4. Share your target Notion page:
   - Go to the Notion page you want to use as the root
   - Click **Share**
   - Add your integration to give it access
5. Get your **Notion Root Page ID**:
   - Copy link to your page
   - Example: `https://www.notion.so/workspace/Your-Page-abcdef1234567890abcdef1234567890`
   - Use: `abcdef1234567890abcdef1234567890`

### 3. Configure `.env`

Copy `.env.sample` to `.env` and fill in all values:

```bash
cp .env.sample .env
```

Fill in:
- ✅ `BASECAMP_CLIENT_ID`
- ✅ `BASECAMP_CLIENT_SECRET`
- ✅ `BASECAMP_REDIRECT_URI`
- ✅ `BASECAMP_ACCOUNT_ID`
- ✅ `NOTION_API_KEY`
- ✅ `NOTION_ROOT_PAGE_ID`

Optional filters:
- `FILTER_PROJECT_LABEL` (e.g., "Marketing HQ")
- `FILTER_TOOL_NAME` (e.g., "chat")

---

## 🚀 Usage

Once `.env` is prepared, run:

```bash
ruby basecamp_to_notion_via_api.rb
```

- ✅ Creates Notion pages under your selected root
- ✅ Auto-generates migration banners with Basecamp links
- ✅ Logs progress and API payloads to `./tmp/`
- ✅ Progress is saved in `sync_progress.db`
- ✅ Resume safely after interruption!

- **Include archived Basecamp projects**:

  ```bash
  INCLUDE_ARCHIVED=true ruby basecamp_to_notion_via_api.rb
  ```
---

## 🧩 Filters (Optional)

You can narrow the scope of migration:

**Project label filter:**
Only sync projects matching label (partial, case-insensitive).

```env
FILTER_PROJECT_LABEL="Marketing HQ"
```

**Tool name filter:**
Only sync specific Basecamp tool types.

Valid values:
```
message_board, schedule, vault, chat, todoset, kanban_board, questionnaire, inbox
```

Example:

```env
FILTER_TOOL_NAME="chat"
```

✅ Filters are safe — progress tracker and resume flow fully supported.

---

## 🧭 Progress Tracking

- Local SQLite: `sync_progress.db`
- Tracks:
  - ✅ Projects
  - ✅ Tools
  - ✅ Items (messages, chats, todos...)
- Resume anytime: re-run the script!

Inspect manually:

```bash
sqlite3 sync_progress.db
```

Final sync report:
→ Written to `sync_report.json` at end of run.

---

## 🧩 Reset Mode

If you want to perform a full fresh sync, starting from a clean state, you can enable `RESET` mode.

Set the environment variable:

```bash
RESET=true ruby basecamp_to_notion_via_api.rb
```

---

## 🧩 Limitations & Notes on Files and Assets

### 🚧 Basecamp Files Are Protected

- Basecamp's media files require authentication.
- They are **not** public.
- ✅ API fetches them during sync, but Notion API currently does not support uploading.

### 🚧 Notion API Limitation

- No file upload support (yet).
- ✅ Rich text, embeds, links, and external media **are** supported.
- ✅ External services (e.g., YouTube, Giphy) work well.

### ✅ Clean Fallback

- Each Notion page includes a yellow migration banner:
  > 🏕️ Migrated from Basecamp on DD/MM/YYYY — 🔗 https://3.basecamp.com/...

- For media:
  - ✅ External links are preserved.
  - ✅ Internal Basecamp assets include source link.
  - ❌ No broken placeholders.

---

## 🛠️ Development

Logs:
→ API calls and Notion block payloads are saved to `./tmp/`

Schema:
→ Auto-created, or run manually:

```bash
ruby database/schema.rb
```

SQLite progress DB:
→ Inspect with:

```bash
sqlite3 sync_progress.db
```

Debug mode:
→ Payload dumps in `./tmp/`
→ Safe to delete between runs.

---

## ✅ Status: Ready ✅

- Fully tested end-to-end
- Multi-project and multi-hour runs safe
- Resume support: ✅
- Migration banners ✅
- Progress DB ✅
- Sync reports ✅

---

## 📋 Roadmap (Potentially)

- [ ] Bug: Some figcaptions are doubling up, given our issues with assets I've not resolved this yet
- [ ] Delta sync: sync only updated Basecamp content
- [ ] Parallelise projects (right now we parallelise tools per project)
- [ ] Media upload support (when Notion API allows)

---

## 👨‍💻 Author

Built by **Tom Meier**

> Crafted for high-fidelity Basecamp → Notion migration.
> Production safe, multi-hour runs. Reliable. Beautiful output.

---

## 🏕️ Notes

> ✅ Every Notion page includes:
>
> _“Migrated from Basecamp on DD/MM/YYYY — 🔗 Original Basecamp URL”_

> ✅ Progress is checkpointed and resumable.

> ✅ No media placeholders — fallback links ensure traceability.

---

## 📩 Questions?

If you get stuck:
- ✅ Check `tmp/` for debug logs
- ✅ Review `sync_progress.db`
- ✅ Open any handler file to customize Notion formatting

---

### ❓ FAQ

**Q: Will `RESET=true` delete my existing Notion pages?**
A: No. RESET only clears local files and progress tracking. Existing Notion pages must be deleted manually if you want a fully clean start.

**Q: Can I resume a sync if my internet drops?**
A: Yes! The script is checkpointed and safe to resume. Simply run it again without `RESET=true`.

**Q: Can I run with filters and RESET together?**
A: Yes. For example:
```bash
RESET=true FILTER_PROJECT_LABEL="My Project" ruby basecamp_to_notion_via_api.rb
