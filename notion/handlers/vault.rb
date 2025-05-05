# /notion/handlers/vault.rb

require_relative '../../basecamp/fetch'
require_relative '../blocks'
require_relative '../helpers'
require_relative '../pages'
require_relative '../../utils/media_extractor'

module Notion
  module Handlers
    module Vault
      extend ::Utils::Logging

      MAX_VAULT_DOCS_PER_PAGE = 100

      def self.call(project, tool, parent_page_id, headers, progress)
        log "🔧 Handling vault tool: #{tool['title']}"
        url = tool["url"].sub(/\.json$/, '/documents.json')
        documents = Basecamp::Fetch.load_json(URI(url), headers)

        if documents.empty?
          log "📭 No documents found for '#{tool['title']}'"
          return []
        end

        log "🧩 Total vault documents to process: #{documents.size}"

        document_chunks = documents.each_slice(MAX_VAULT_DOCS_PER_PAGE).to_a
        needs_subpages = document_chunks.size > 1

        parent_tool_page = if needs_subpages
          Notion::Pages.create_page(
            { "name" => "📄 #{tool['title']}", "url" => tool["url"] },
            parent_page_id,
            children: [],
            context: "Vault Parent Page",
            url: tool["url"]
          )
        end

        document_chunks.each_with_index do |chunk, index|
          page_title = needs_subpages ? "📄 #{tool['title']} (Part #{index + 1})" : "📄 #{tool['title']}"
          sub_page_parent = needs_subpages ? parent_tool_page["id"] : parent_page_id

          page = Notion::Pages.create_page(
            { "name" => page_title, "url" => tool["url"] },
            sub_page_parent,
            children: [],
            context: "Vault Subpage #{index + 1}",
            url: tool["url"]
          )
          page_id = page["id"]

          unless page_id
            warn "🚫 Skipping vault subpage #{index + 1}: page creation failed."
            next
          end

          log "📄 Created vault page: #{page_id} for Part #{index + 1} with #{chunk.size} documents"

          blocks = []

          chunk.each_with_index do |doc, doc_idx|
            next unless doc

            begin
              context = "Vault Document #{doc_idx + 1} of #{chunk.size}: #{doc["title"]}"
              raw_preview = doc.to_json[0..500]
              log "🧩 Raw Basecamp document #{doc_idx + 1}/#{chunk.size}: #{raw_preview}"

              # ✅ Progress: upsert item at start
              progress.upsert_item(
                basecamp_id: doc["id"],
                project_basecamp_id: project["id"],
                tool_name: "vault"
              )

              item_blocks = []

              # 📄 Title
              item_blocks += Notion::Helpers.heading_blocks("📄 #{doc["title"]}", 3, context)

              # 👤 Creator metadata
              creator_name = doc.dig("creator", "name") || "Unknown"
              created_at = Notion::Utils.format_timestamp(doc["created_at"]) rescue "Unknown date"
              item_blocks += Notion::Helpers.callout_blocks("👤 Created by #{creator_name} · 🕗 #{created_at}", "📄", context)

              # 🔗 App URL
              item_blocks << Notion::Helpers.label_and_link_block("🔗", doc["app_url"], context) if doc["app_url"]

              # 📝 Content
              if doc["content"] && !doc["content"].strip.empty?
                content_blocks, embed_blocks = Notion::Blocks.extract_blocks(doc["content"], page_id, context)
                item_blocks += content_blocks if content_blocks.any?
                item_blocks += embed_blocks if embed_blocks.any?
              end

              # Final divider
              item_blocks << Notion::Helpers.divider_block

              blocks += item_blocks

              # 💬 Process comments
              if doc["comments_url"] && doc["comments_count"].to_i > 0
                comment_blocks = fetch_and_build_comments(doc, page_id, headers, context)

                if comment_blocks.any?
                  blocks += Notion::Helpers.comment_section_blocks(comment_blocks, context)
                else
                  log "💬 No comment blocks built for vault document: #{doc["title"]} (#{context})"
                end
              end

              # ✅ Progress: mark item complete
              progress.complete_item(doc["id"], project["id"], "vault")
            rescue => e
              warn "❌ Error processing vault document #{doc["id"]}: #{e.class}: #{e.message}"
              warn "  Full doc content: #{doc.inspect}"
              warn "  Exception backtrace:\n#{e.backtrace.join("\n")}"
              next
            end
          end

          log "🧩 Prepared #{blocks.size} blocks for Vault Part #{index + 1}"

          Notion::Blocks.append_batched(page_id, blocks, context: "Vault Part #{index + 1} - #{tool['title']}")
        end

        log "📦 VaultHandler: Finished processing '#{tool['title']}'"
        []
      end

      def self.fetch_and_build_comments(doc, page_id, headers, parent_context)
        comments = Basecamp::Fetch.load_json(URI(doc["comments_url"]), headers)

        debug "🧩 Raw comments API payload for vault document:\n#{JSON.pretty_generate(comments)}"
        log "💬 Fetched #{comments.size} comments for vault document: #{doc["title"]}"

        return [] if comments.empty?

        comment_blocks = []

        comments.sort_by { |c| c["created_at"] }.each_with_index do |comment, idx|
          comment_context = "#{parent_context} - Comment #{idx + 1} of #{comments.size}"

          comment_blocks << Notion::Helpers.divider_block if idx > 0

          author_name = comment.dig("creator", "name") || "Unknown commenter"
          created_at = Notion::Utils.format_timestamp(comment["created_at"]) rescue "Unknown date"

          comment_blocks += Notion::Helpers.callout_blocks("👤 #{author_name} · 🕗 #{created_at}", "💬", comment_context)
          comment_blocks << Notion::Helpers.empty_paragraph_block

          body_blocks, _files, embed_blocks = ::Utils::MediaExtractor.extract_and_clean(
            comment["content"],
            page_id,
            comment_context
          )

          total_blocks = body_blocks.size + embed_blocks.size
          debug "🧩 MediaExtractor returned #{total_blocks} blocks from comment (#{comment_context})"

          comment_blocks += body_blocks.compact + embed_blocks.compact
        end

        comment_blocks
      end
    end
  end
end
