# notion/auth.rb
#
# Interactive helper to obtain a Notion `token_v2` cookie (private session token)
# via a Selenium-controlled Chrome session. The token is cached locally so the
# browser flow only runs the first time or when the cache is deleted.
#
# Usage:
#   token = Notion::Auth.token  # returns the token string and sets ENV['NOTION_TOKEN_V2']
#
# The cookie is stored in `./cache/notion_token.json` alongside other sync cache
# files. If you need to re-authenticate, simply delete that file.

require 'json'
require 'fileutils'
require 'selenium-webdriver'
require_relative '../config'
require_relative '../utils/logging'

module Notion
  module Auth
    extend ::Utils::Logging

    TOKEN_CACHE_PATH = File.join(CACHE_DIR, 'notion_token.json').freeze
    LOGIN_URL        = 'https://www.notion.so/login'.freeze

    # Public: Ensure we have a valid token_v2 and return it.
    #          – Tries cached token first.
    #          – Otherwise opens a Chrome browser for the user to log in.
    #          – Extracts the `token_v2` cookie and stores it for reuse.
    #
    # Returns the token string (never nil). Exits the program if the token
    # cannot be obtained.
    # Track the last Selenium driver so we can close it on exit
    @last_driver = nil
    at_exit do
      if @last_driver
        begin
          @last_driver.quit
        rescue => e
          warn "[Notion::Auth] Error closing Selenium session: #{e.class}: #{e.message}"
        end
      end
    end

    def self.token
      cached = read_cached_token
      return cached if cached
      token_v2 = acquire_token_via_browser
      ENV['NOTION_TOKEN_V2'] = token_v2 if token_v2
      token_v2
    end

    # --------------------------------------------------------------------
    # Internal helpers

    def self.read_cached_token
      return nil unless File.exist?(TOKEN_CACHE_PATH)
      data = JSON.parse(File.read(TOKEN_CACHE_PATH)) rescue nil
      if data && data['token_v2'] && !data['token_v2'].empty?
        debug "🔑 [Notion::Auth] Using cached token_v2 (#{TOKEN_CACHE_PATH})"
        ENV['NOTION_TOKEN_V2'] ||= data['token_v2']
        return data['token_v2']
      end
      nil
    end

    def self.acquire_token_via_browser
      Utils::ChromedriverSetup.ensure_driver_available
      options = Selenium::WebDriver::Chrome::Options.new
      profile_dir = ENV['NOTION_CHROME_PROFILE_DIR'] || File.expand_path('~/.notion_chrome')
      options.add_argument("--user-data-dir=#{profile_dir}")
      options.add_argument('--profile-directory=Default')
      options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'

      driver = Selenium::WebDriver.for(:chrome, options: options)
      notion_login_url = ENV.fetch('NOTION_LOGIN_URL', 'https://www.notion.so/login')
      puts "🔐 Opening Notion login page: #{notion_login_url}"
      driver.navigate.to(notion_login_url)
      puts "👩‍💻 Please sign in to Notion if prompted… (timeout: 300s)"
      wait_for_login(driver)
      token = extract_token(driver)
      driver.quit
      if token
        puts "✅ Notion token_v2 cookie captured and ready for use"
        FileUtils.mkdir_p(File.dirname(TOKEN_CACHE_PATH))
        File.write(TOKEN_CACHE_PATH, JSON.pretty_generate({ token_v2: token, fetched_at: Time.now.to_i }))
        debug "💾 [Notion::Auth] token_v2 cached to #{TOKEN_CACHE_PATH}"
      else
        warn "❌ token_v2 cookie not found after login"
      end
      token
    end

    def self.wait_for_login(driver)
      require 'timeout'
      Timeout.timeout(300) do
        loop do
          cookies = driver.manage.all_cookies
          break if cookies.any? { |c| c[:name] == 'token_v2' }
          sleep 1
        end
      end
    rescue Timeout::Error
      warn "⚠️ Notion login timeout after 300s; continuing with whatever cookies were set…"
    end

    def self.extract_token(driver)
      cookies = driver.manage.all_cookies
      token_cookie = cookies.find { |c| c[:name] == 'token_v2' }
      token_cookie ? token_cookie[:value] : nil
    end

  end
end
