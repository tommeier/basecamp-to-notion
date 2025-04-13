# /notion/api.rb
require 'net/http'
require 'json'
require 'uri'
require_relative '../config'
require_relative '../utils/logging'
require_relative '../utils/http'

module Notion
  module API
    extend ::Utils::Logging

    def self.default_headers
      {
        "Authorization" => "Bearer #{NOTION_API_KEY}",
        "Notion-Version" => "2022-06-28",
        "Content-Type" => "application/json"
      }
    end

    def self.post_json(uri, payload, headers = default_headers, context: nil)
      ::Utils::HTTP.post_json(uri, payload, headers, context: context)
    end

    def self.patch_json(uri, payload, headers = default_headers, context: nil)
      ::Utils::HTTP.patch_json(uri, payload, headers, context: context)
    end
  end
end
