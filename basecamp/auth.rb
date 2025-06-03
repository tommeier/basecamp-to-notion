# basecamp/auth.rb
require 'uri'
require 'json'
require 'fileutils'
require 'cgi'
require_relative '../config'
require_relative '../utils/logging'
require_relative '../utils/http'

module Basecamp
  module Auth
    def self.token
      FileUtils.mkdir_p(CACHE_DIR)
      token_path = File.join(CACHE_DIR, "basecamp_token.json")
      unless File.exist?(token_path)
        puts "\n🔐 Visit to authorize Basecamp:\n"
        puts "👉 https://launchpad.37signals.com/authorization/new?type=web_server&client_id=#{BASECAMP_CLIENT_ID}&redirect_uri=#{CGI.escape(BASECAMP_REDIRECT_URI)}"
        puts "\nPaste the code from the redirect URL:"
        print "> "
        code = gets.strip
        uri = URI("https://launchpad.37signals.com/authorization/token")

        Utils::Logging.debug "✅ BASECAMP_CLIENT_ID: #{BASECAMP_CLIENT_ID.inspect}"
        Utils::Logging.debug "✅ BASECAMP_CLIENT_SECRET: #{BASECAMP_CLIENT_SECRET.inspect}"
        Utils::Logging.debug "✅ BASECAMP_REDIRECT_URI: #{BASECAMP_REDIRECT_URI.inspect}"

        Utils::Logging.debug "🚀 Payload: #{{
          type: "web_server",
          client_id: BASECAMP_CLIENT_ID,
          client_secret: BASECAMP_CLIENT_SECRET,
          redirect_uri: BASECAMP_REDIRECT_URI,
          code: code
        }.inspect}"

        res = ::Utils::HTTP.post_json(uri, {
          type: "web_server",
          client_id: BASECAMP_CLIENT_ID,
          client_secret: BASECAMP_CLIENT_SECRET,
          redirect_uri: BASECAMP_REDIRECT_URI,
          code: code
        })
        File.write(token_path, JSON.pretty_generate(res))
      end
      JSON.parse(File.read(token_path))["access_token"]
    end
  end
end