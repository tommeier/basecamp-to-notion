# /notion/handlers/message_board.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require_relative '../../utils/media_extractor'
require_relative '../../config'
require_relative '../sanitization'

module Notion
  module Handlers
    module MessageBoard
      extend ::Utils::Logging

      MAX_MESSAGES_PER_PAGE = 100

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling message board tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/messages.json')
        messages = Basecamp::Fetch.load_json(URI(url), headers)

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

          context = "Message #{msg_idx + 1} of #{messages.size}: #{msg["title"]}"
          log "📝 Creating page for #{context}"

          # ✅ Progress: upsert item at start
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

          blocks = build_message_blocks([msg], nil, message_page_id, board_title, headers).compact
          log "🧩 Prepared #{blocks.size} blocks for #{context}"

          block_batches = blocks.each_slice(MAX_CHILDREN_PER_BLOCK).to_a
          block_batches.each_with_index do |batch, batch_idx|
            log "🪵 Appending message batch #{batch_idx + 1}/#{block_batches.size} (size: #{batch.size}) to message page #{message_page_id}"

            Notion::API.patch_json(
              "https://api.notion.com/v1/blocks/#{message_page_id}/children",
              { children: batch },
              context: "#{context} - Append Message Batch #{batch_idx + 1}"
            )
          end

          process_message_comments(msg, message_page_id, headers, msg_idx + 1, messages.size)

          # ✅ Progress: mark item complete
          progress.complete_item(msg["id"], project["id"], "message_board")
        end
      end

      def self.format_message_title(msg, part_number, total_parts)
        date = Notion::Utils.format_timestamp(msg["created_at"]).split(' ').first rescue "unknown-date"
        title = msg["title"].strip rescue "Untitled"

        if total_parts == 1
          "#{date} #{title}"
        else
          "#{date} - #{title}"
        end
      end

      def self.build_message_blocks(messages, tool, page_id, board_title, headers)
        blocks = []

        messages.each_with_index do |msg, msg_idx|
          next unless msg

          context = "Message #{msg_idx + 1} of #{messages.size}: #{msg["title"]}"
          log "🧹 Processing #{context}"
          debug "🧩 Raw message API payload:\n#{JSON.pretty_generate(msg)}"

          # Title
          blocks += Notion::Helpers.heading_block("📝 #{msg["title"]}", 3, context).compact

          # Metadata
          creator_name = msg.dig("creator", "name") || "Unknown"
          created_at = Notion::Utils.format_timestamp(msg["created_at"]) rescue "Unknown date"
          blocks += Notion::Helpers.callout_block("👤 Author: #{creator_name} · 🕗 #{created_at}", "🖊️", context).compact

          # Spacer
          blocks << Notion::Helpers.text_block(" ", context).first

          # Body
          message_blocks, _files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
            msg["content"],
            page_id,
            context
          )
          total_blocks = message_blocks.size + embed_blocks.size
          debug "🧩 MediaExtractor returned #{total_blocks} blocks from message body (#{context})"

          blocks += message_blocks.compact + embed_blocks.compact

          # Spacer
          blocks << Notion::Helpers.text_block(" ", context).first

          # Final divider
          blocks << Notion::Helpers.divider_block
        end

        blocks.compact
      end

      def self.process_message_comments(msg, page_id, headers, msg_idx, total_messages)
        return unless msg && msg["comments_url"]

        context = "Message #{msg_idx} of #{total_messages}: #{msg["title"]}"

        comments_url = msg["comments_url"]
        comments = Basecamp::Fetch.load_json(URI(comments_url), headers)

        debug "🧩 Raw comments API payload:\n#{JSON.pretty_generate(comments)}"
        log "💬 Fetched #{comments.size} comments for message '#{msg["title"]}'"

        return if comments.empty?

        # ✅ Step 1: Create dynamic wrapper block
        comment_header = "💬 Comments (#{comments.size})"
        result = Notion::API.patch_json(
          "https://api.notion.com/v1/blocks/#{page_id}/children",
          { children: [{
            object: "block",
            type: "callout",
            callout: {
              icon: { type: "emoji", emoji: "💬" },
              rich_text: [{
                type: "text",
                text: { content: comment_header }
              }]
            }
          }] },
          context: "#{context} - Create Comment Wrapper"
        )

        wrapper_block_id = result.dig("results", 0, "id")
        unless wrapper_block_id
          error "🚨 [process_message_comments] wrapper_block_id is nil for context: #{context} — aborting to prevent invalid appends!"
          raise "wrapper_block_id is nil — aborting"
        end
        log "✅ Created comment wrapper block ID #{wrapper_block_id} for context: #{context}"

        # ✅ Step 2: Prepare comment blocks
        comment_blocks = []

        comments.sort_by { |c| c["created_at"] }.each_with_index do |comment, idx|
          comment_context = "Comment by #{comment.dig("creator", "name")}"

          comment_blocks << Notion::Helpers.divider_block if idx > 0

          comment_author = comment.dig("creator", "name") || "Unknown commenter"
          comment_time = Notion::Utils.format_timestamp(comment["created_at"]) rescue "Unknown date"

          comment_blocks += Notion::Helpers.callout_block("👤 #{comment_author} · 🕗 #{comment_time}", "💬", comment_context).compact
          comment_blocks << Notion::Helpers.text_block(" ", comment_context).first

          comment_body_blocks, _files, comment_embeds = ::Utils::MediaExtractor.extract_and_clean(
            comment["content"],
            page_id,
            comment_context
          )
          total_comment_blocks = comment_body_blocks.size + comment_embeds.size
          debug "🧩 MediaExtractor returned #{total_comment_blocks} blocks from comment (#{comment_context})"

          comment_blocks += comment_body_blocks.compact + comment_embeds.compact
        end

        log "🧩 Prepared #{comment_blocks.size} comment blocks for message '#{msg["title"]}'"

        # ✅ Step 3: Append comments in safe batches
        comment_batches = comment_blocks.each_slice(MAX_CHILDREN_PER_BLOCK).to_a

        if comment_batches.empty?
          log "⚠️ No comment batches prepared for message '#{msg["title"]}'"
        else
          comment_batches.each_with_index do |batch, batch_idx|
            sanitized_batch = ::Notion::Sanitization.deep_sanitize_blocks(batch)

            log "🪵 Appending comment batch #{batch_idx + 1}/#{comment_batches.size} (size: #{sanitized_batch.size}) to wrapper #{wrapper_block_id}"

            Notion::API.patch_json(
              "https://api.notion.com/v1/blocks/#{wrapper_block_id}/children",
              { children: sanitized_batch },
              context: "#{context} - Append Comment Batch #{batch_idx + 1}"
            )

            log "✅ Appended comment batch #{batch_idx + 1}/#{comment_batches.size} to wrapper #{wrapper_block_id}"
          end
        end
      end
    end
  end
end
