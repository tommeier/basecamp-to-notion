# notion/handlers/message_board.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require_relative '../../utils/media_extractor'
require_relative '../../config'
require_relative '../sanitization'
require 'thread'

module Notion
  module Handlers
    module MessageBoard
      extend ::Utils::Logging

      MAX_MESSAGES_PER_PAGE = 100

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling message board tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/messages.json')
        messages = Basecamp::Fetch.load_json(URI(url), headers)

        # Apply optional title filter to narrow down to a specific message for faster feedback cycles
        if defined?(FILTER_MESSAGE_TITLE) && FILTER_MESSAGE_TITLE && !FILTER_MESSAGE_TITLE.empty?
          before_count = messages.size
          messages.select! { |m| m["title"]&.match?(/#{FILTER_MESSAGE_TITLE}/i) }
          log "🔍 FILTER_MESSAGE_TITLE applied (#{FILTER_MESSAGE_TITLE.inspect}) — #{messages.size}/#{before_count} messages match"
        end

        if messages.empty?
          log "📬 No messages found for '#{tool['title']}'"
          return []
        end

        log "🧹 Total messages to process: #{messages.size}"

        board_page_id = parent_page_id
        log "🧭 Using existing board page: #{board_page_id}"

        sorted_messages = messages.sort_by { |msg| msg["created_at"] }
        message_chunks = sorted_messages.each_slice(MAX_MESSAGES_PER_PAGE).to_a

        if message_chunks.size == 1
          log "🧹 Small board — messages go directly under board page"
          process_message_chunk(message_chunks.first, board_page_id, headers, tool["title"], 1, 1, project, progress)
        else
          log "🧩 Large board detected: splitting into #{message_chunks.size} parts"

          message_chunks.each_with_index do |chunk, index|
            part_title = "📝 #{index + 1} - #{tool["title"]}"
            part_page = Notion::Pages.create_page(
              { "name" => part_title, "url" => tool["url"] },
              board_page_id,
              children: [],
              context: "Message Board Part #{index + 1}",
              url: tool["url"]
            )
            part_page_id = part_page&.dig("id")

            unless part_page_id
              warn "❌ Skipping part page #{index + 1}: page creation failed."
              next
            end

            log "📄 Created part page #{part_page_id} for #{part_title} (#{chunk.size} messages)"

            process_message_chunk(chunk, part_page_id, headers, tool["title"], index + 1, message_chunks.size, project, progress)
          end
        end

        log "📊 Finished message board '#{tool['title']}'"
        []
      end

      def self.process_message_chunk(messages, parent_page_id, headers, board_title, part_number, total_parts, project, progress)
        messages.each_with_index do |msg, msg_idx|
          next unless msg
          begin
            context = "Message #{msg_idx + 1} of #{messages.size}: #{msg["title"]}"
            log "📝 Creating page for #{context}"

            progress.upsert_item(
              basecamp_id: msg["id"],
              project_basecamp_id: project["id"],
              tool_name: "message_board"
            )

            message_page = Notion::Pages.create_page(
              { "name" => format_message_title(msg, part_number, total_parts), "url" => msg["app_url"] || msg["url"] },
              parent_page_id,
              children: [],
              context: "Message Page",
              url: msg["app_url"] || msg["url"]
            )
            message_page_id = message_page&.dig("id")

            unless message_page_id
              warn "❌ Skipping message page: creation failed for #{context}"
              next
            end

            log "📄 Created message page #{message_page_id} for #{context}"

            blocks = build_message_blocks([msg], nil, message_page_id, board_title, headers)
            log "🧩 Prepared #{blocks.size} blocks for #{context}"

            Notion::Blocks.append_batched(message_page_id, blocks, context: context)

            process_message_comments(msg, message_page_id, headers, msg_idx + 1, messages.size)

            progress.complete_item(msg["id"], project["id"], "message_board")
          rescue => e
            warn "❌ Error processing message #{msg["id"]}: #{e.class}: #{e.message}"
            warn "  Full message content: #{msg.inspect}"
            warn "  Exception backtrace:\n#{e.backtrace.join("\n")}" 
            next
          end
        end
      end

      def self.format_message_title(msg, part_number, total_parts)
        date = Notion::Utils.format_timestamp(msg["created_at"]).split(' ').first rescue "unknown-date"
        title = msg["title"].strip rescue "Untitled"
        total_parts == 1 ? "#{date} #{title}" : "#{date} - #{title}"
      end

      def self.build_message_blocks(messages, _tool, page_id, _board_title, headers)
        blocks = []

        messages.each_with_index do |msg, msg_idx|
          next unless msg

          context = "Message #{msg_idx + 1} of #{messages.size}: #{msg["title"]}"
          log "🧹 Processing #{context}"
          debug "🧩 Raw message API payload:\n#{JSON.pretty_generate(msg)}"

          blocks += Notion::Helpers.heading_blocks("📝 #{msg["title"]}", 3, context)
          creator_name = msg.dig("creator", "name") || "Unknown"
          created_at = Notion::Utils.format_timestamp(msg["created_at"]) rescue "Unknown date"
          blocks += Notion::Helpers.callout_blocks("👤 Author: #{creator_name} · 🕗 #{created_at}", "🖊️", context)
          blocks << Notion::Helpers.empty_paragraph_block

          message_blocks, _files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
            msg["content"], page_id, context
          )
          debug "🧩 MediaExtractor returned #{message_blocks.size + embed_blocks.size} blocks (#{context})"
          blocks += message_blocks + embed_blocks

          blocks << Notion::Helpers.empty_paragraph_block
          blocks << Notion::Helpers.divider_block
        end

        blocks
      end

      def self.build_comment_blocks(comments, parent_id)
        sorted = comments.sort_by { |c| c["created_at"] }
        max_threads = [::COMMENT_UPLOAD_THREADS, 1].max

        # Fallback to sequential processing when concurrency is disabled
        if max_threads <= 1
          return sequential_build_comment_blocks(sorted, parent_id)
        end

        blocks_by_idx = Array.new(sorted.size)
        thread_pool = []

        sorted.each_with_index do |comment, idx|
          # Respect pool size limit
          loop do
            thread_pool.reject! { |t| !t.alive? }
            break if thread_pool.size < max_threads
            sleep 0.01
          end

          thread_pool << Thread.new(comment, idx) do |c, i|
            begin
              local_blocks = []
              context = "Comment by #{c.dig('creator', 'name') || 'Unknown'}"
              local_blocks << Notion::Helpers.divider_block if i > 0

              name = c.dig('creator', 'name') || 'Unknown'
              time = Notion::Utils.format_timestamp(c['created_at']) rescue 'Unknown date'
              local_blocks += Notion::Helpers.callout_blocks("👤 #{name} · 🕗 #{time}", '💬', context)
              local_blocks << Notion::Helpers.empty_paragraph_block

              body_blocks, _files, embeds = ::Utils::MediaExtractor.extract_and_clean(c['content'], parent_id, context)
              local_blocks += body_blocks + embeds

              blocks_by_idx[i] = local_blocks
            rescue => e
              warn "❌ Error building comment block idx=#{i}: #{e.class}: #{e.message}"
            end
          end
        end

        thread_pool.each(&:join)
        blocks_by_idx.compact.flatten
      end

      # Internal: original sequential logic retained for clarity
      def self.sequential_build_comment_blocks(sorted_comments, parent_id)
        blocks = []
        sorted_comments.each_with_index do |comment, idx|
          context = "Comment by #{comment.dig('creator', 'name') || 'Unknown'}"
          blocks << Notion::Helpers.divider_block if idx > 0

          name = comment.dig('creator', 'name') || 'Unknown'
          time = Notion::Utils.format_timestamp(comment['created_at']) rescue 'Unknown date'
          blocks += Notion::Helpers.callout_blocks("👤 #{name} · 🕗 #{time}", '💬', context)
          blocks << Notion::Helpers.empty_paragraph_block

          body_blocks, _files, embeds = ::Utils::MediaExtractor.extract_and_clean(comment['content'], parent_id, context)
          blocks += body_blocks + embeds
        end
        blocks
      end

      def self.process_message_comments(msg, page_id, headers, msg_idx, total_messages)
        return unless msg && msg["comments_url"]

        context = "Message #{msg_idx} of #{total_messages}: #{msg["title"]}"
        comments = Basecamp::Fetch.load_json(URI(msg["comments_url"]), headers)
        return if comments.empty?

        log "💬 Fetched #{comments.size} comments for #{context}"

        children = Notion::Helpers.callout_blocks("💬 Comments (#{comments.size})", "💬", context)
        result = Notion::API.patch_json(
          "https://api.notion.com/v1/blocks/#{page_id}/children",
          { children: children },
          context: "#{context} - Create Comment Wrapper"
        )
        wrapper_id = result.dig("results", 0, "id")
        raise "❌ wrapper_block_id is nil — aborting" unless wrapper_id

        log "✅ Created wrapper block ID #{wrapper_id} for #{context}"

        comment_blocks = build_comment_blocks(comments, page_id)
        Notion::Blocks.append_batched(wrapper_id, comment_blocks, context: "#{context} - Comments")
      end
    end
  end
end
