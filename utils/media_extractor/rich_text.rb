# utils/media_extractor/rich_text.rb

require_relative './helpers'
require_relative './resolver'
require_relative './logger'

module Utils
  module MediaExtractor
    module RichText
      extend ::Utils::Logging
      extend ::Utils::MediaExtractor::Helpers
      extend ::Utils::MediaExtractor::Resolver

      def self.extract_rich_text_from_fragment(fragment, context, parent_page_id)
        rich_text = []
        embed_blocks = []

        fragment.each_with_index do |child, idx|
          next if child.comment?

          case child.name
          when 'text', nil
            text = child.text
            segment = Helpers.text_segment(text)
            rich_text << segment if segment

          when 'a'
            href = Helpers.clean_url(child['href'])
            link_text = child.text

            # ✅ Add spacing if previous or next sibling exists
            link_text = " #{link_text}" unless idx.zero?
            link_text = "#{link_text} " unless idx == fragment.size - 1

            if href && !href.empty?
              if Resolver.basecamp_asset_url?(href)
                resolved_url = Resolver.resolve_basecamp_url(href, context)
                if resolved_url
                  if Resolver.embeddable_media_url?(resolved_url)
                    embed_blocks << Helpers.build_embed_block(resolved_url, context)
                  else
                    segment = Helpers.text_segment(link_text, link: resolved_url)
                    rich_text << segment if segment
                  end
                else
                  Helpers.log_manual_upload(href, parent_page_id, context)
                  fallback_segment = Helpers.text_segment("Basecamp asset: 🔗 #{link_text.strip}", link: href.strip)
                  rich_text << fallback_segment if fallback_segment
                end

              elsif Resolver.embeddable_media_url?(href)
                embed_blocks << Helpers.build_embed_block(href, context)
              else
                segment = Helpers.text_segment(link_text, link: href)
                rich_text << segment if segment
              end
            end

          when 'strong', 'b'
            segment = Helpers.text_segment(child.text.strip)
            if segment
              segment[:annotations] ||= {}
              segment[:annotations][:bold] = true
              rich_text << segment
            end

          when 'em', 'i'
            segment = Helpers.text_segment(child.text.strip)
            if segment
              segment[:annotations] ||= {}
              segment[:annotations][:italic] = true
              rich_text << segment
            end

          when 'u'
            segment = Helpers.text_segment(child.text.strip)
            if segment
              segment[:annotations] ||= {}
              segment[:annotations][:underline] = true
              rich_text << segment
            end

          when 'strike', 's', 'del'
            segment = Helpers.text_segment(child.text.strip)
            if segment
              segment[:annotations] ||= {}
              segment[:annotations][:strikethrough] = true
              rich_text << segment
            end

          when 'code'
            segment = Helpers.text_segment(child.text.strip)
            if segment
              segment[:annotations] ||= {}
              segment[:annotations][:code] = true
              rich_text << segment
            end

          else
            segment = Helpers.text_segment(child.text.strip)
            rich_text << segment if segment
          end
        end

        [rich_text.compact, embed_blocks.compact]
      end
    end
  end
end
