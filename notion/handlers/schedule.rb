# /notion/handlers/schedule.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require 'thread'
require 'json'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Schedule
      extend ::Utils::Logging

      MAX_EVENTS_PER_PAGE = 100

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling schedule tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/entries.json')
        entries = Basecamp::Fetch.load_json(URI(url), headers)

        if entries.empty?
          log "📭 No schedule entries found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total schedule entries to process: #{entries.size}"

        entry_chunks = entries.each_slice(MAX_EVENTS_PER_PAGE).to_a
        needs_subpages = entry_chunks.size > 1

        parent_tool_page = if needs_subpages
          Notion::Pages.create_page(
            { "name" => "📅 #{tool['title']}", "url" => tool["url"] },
            parent_page_id,
            children: [],
            context: "Schedule Parent Page",
            url: tool["url"]
          )
        end

        entry_chunks.each_with_index do |chunk, index|
          page_title = needs_subpages ? "📅 #{tool['title']} (Part #{index + 1})" : "📅 #{tool['title']}"
          sub_page_parent = needs_subpages ? parent_tool_page["id"] : parent_page_id

          page = Notion::Pages.create_page(
            { "name" => page_title, "url" => tool["url"] },
            sub_page_parent,
            children: [],
            context: "Schedule Subpage #{index + 1}",
            url: tool["url"]
          )
          page_id = page["id"]

          unless page_id
            warn "🚫 Skipping schedule subpage #{index + 1}: page creation failed."
            next
          end

          log "📄 Created schedule page: #{page_id} for Part #{index + 1} with #{chunk.size} entries"

          blocks = []

          chunk.each_with_index do |entry, entry_idx|
            next unless entry
            begin
              context = "Schedule Entry #{entry_idx + 1} of #{chunk.size}: #{entry["summary"]}"
              raw_preview = entry.to_json[0..500]
              log "🧩 Raw Basecamp entry #{entry_idx + 1}/#{chunk.size}: #{raw_preview}"

              # ✅ Progress: upsert item at start
              progress.upsert_item(
                basecamp_id: entry["id"],
                project_basecamp_id: project["id"],
                tool_name: "schedule"
              )

              item_blocks = []

              # 🔥 Title heading
              item_blocks += Notion::Helpers.heading_blocks("📅 #{entry["summary"]}", 3, context)

              # 🧩 Metadata callout: Creator + Time
              creator_name = entry.dig("creator", "name") || "Unknown"
              created_at = Notion::Utils.format_timestamp(entry["created_at"]) rescue "Unknown date"
              item_blocks += Notion::Helpers.callout_blocks("👤 Created by #{creator_name} · 🕗 #{created_at}", "🗓️", context)

              # 🕒 Event timing
              if entry["starts_at"]
                starts_at = Notion::Utils.format_timestamp(entry["starts_at"]) rescue "Unknown start"
                ends_at = entry["ends_at"] ? Notion::Utils.format_timestamp(entry["ends_at"]) : "Unknown end"
                item_blocks += Notion::Helpers.callout_blocks("🕒 #{starts_at} → #{ends_at}", "📅", context)
              end

              # 📝 Description
              if entry["description"] && !entry["description"].strip.empty?
                desc_blocks, desc_embeds = Notion::Blocks.extract_blocks(entry["description"], page_id, context)
                item_blocks += desc_blocks if desc_blocks.any?
                item_blocks += desc_embeds if desc_embeds.any?
              end

              # 📍 Location
              item_blocks << Notion::Helpers.label_and_link_block("📍 Location:", entry["location"], context) if entry["location"]&.strip != ""

              # 🔗 App URL
              item_blocks << Notion::Helpers.label_and_link_block("🔗", entry["app_url"], context) if entry["app_url"]

              # ✅ Final divider
              item_blocks << Notion::Helpers.divider_block

              # Append blocks
              blocks += item_blocks

              # 💬 Process comments
              if entry["comments_count"].to_i > 0 && entry["comments_url"]
                comment_blocks = fetch_and_build_comments(entry, page_id, headers, context)

                if comment_blocks.any?
                  blocks += Notion::Helpers.comment_section_blocks(comment_blocks, context)
                else
                  log "💬 No comment blocks built for schedule entry: #{entry["summary"]} (#{context})"
                end
              end

              # ✅ Progress: mark item complete
              progress.complete_item(entry["id"], project["id"], "schedule")
            rescue => e
              warn "❌ Error processing schedule entry #{entry["id"]}: #{e.class}: #{e.message}"
              warn "  Full entry content: #{entry.inspect}"
              warn "  Exception backtrace:\n#{e.backtrace.join("\n")}"
              next
            end
          end

          log "🧩 Prepared #{blocks.size} blocks for Schedule Part #{index + 1}"

          Notion::Blocks.append_batched(page_id, blocks, context: "Schedule Part #{index + 1} - #{tool['title']}")
        end

        log "📦 ScheduleHandler: Finished processing '#{tool['title']}'"
        []
      end

      def self.fetch_and_build_comments(entry, page_id, headers, parent_context)
        comments = Basecamp::Fetch.load_json(URI(entry["comments_url"]), headers)

        debug "🧩 Raw comments API payload for schedule entry:\n#{JSON.pretty_generate(comments)}"
        log "💬 Fetched #{comments.size} comments for schedule entry: #{entry["summary"]}"

        return [] if comments.empty?

        sorted = comments.sort_by { |c| c["created_at"] }
        max_threads = [::COMMENT_UPLOAD_THREADS, 1].max

        # Sequential path
        if max_threads <= 1
          return sequential_fetch_and_build_comments(sorted, page_id, parent_context)
        end

        blocks_by_idx = Array.new(sorted.size)
        pool = []

        sorted.each_with_index do |comment, idx|
          # Respect pool size
          loop do
            pool.reject! { |t| !t.alive? }
            break if pool.size < max_threads
            sleep 0.01
          end

          pool << Thread.new(comment, idx) do |c, i|
            begin
              local_blocks = []
              ctx = "#{parent_context} - Comment #{i + 1} of #{sorted.size}"

              local_blocks << Notion::Helpers.divider_block if i > 0

              author_name = c.dig('creator', 'name') || 'Unknown commenter'
              created_at  = Notion::Utils.format_timestamp(c['created_at']) rescue 'Unknown date'
              local_blocks += Notion::Helpers.callout_blocks("👤 #{author_name} · 🕗 #{created_at}", '💬', ctx)
              local_blocks << Notion::Helpers.empty_paragraph_block

              body_blocks, _files, embeds = ::Utils::MediaExtractor.extract_and_clean(c['content'], page_id, ctx)
              local_blocks += body_blocks.compact + embeds.compact

              blocks_by_idx[i] = local_blocks
            rescue => e
              warn "❌ Error building schedule comment idx=#{i}: #{e.class}: #{e.message}"
            end
          end
        end

        pool.each(&:join)
        blocks_by_idx.compact.flatten
      end

      # Sequential fallback helper
      def self.sequential_fetch_and_build_comments(sorted_comments, page_id, parent_context)
        comment_blocks = []
        sorted_comments.each_with_index do |comment, idx|
          comment_context = "#{parent_context} - Comment #{idx + 1} of #{sorted_comments.size}"

          comment_blocks << Notion::Helpers.divider_block if idx > 0

          author_name = comment.dig("creator", "name") || "Unknown commenter"
          created_at  = Notion::Utils.format_timestamp(comment["created_at"]) rescue "Unknown date"

          comment_blocks += Notion::Helpers.callout_blocks("👤 #{author_name} · 🕗 #{created_at}", "💬", comment_context)
          comment_blocks << Notion::Helpers.empty_paragraph_block

          body_blocks, _files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
            comment["content"],
            page_id,
            comment_context
          )

          comment_blocks += body_blocks.compact + embed_blocks.compact
        end
        comment_blocks
      end
    end
  end
end
