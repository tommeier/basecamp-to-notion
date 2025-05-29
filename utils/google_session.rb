# utils/google_session.rb
# Manages a reusable Selenium session for Google authentication.
# Provides cookies for authenticated requests to googleusercontent URLs.
# Uses a simple approach matching BasecampSession for reliability

require 'timeout'
require 'json'
require 'uri'
require 'net/http'
require 'thread'
require 'fileutils' # For creating directories
require_relative './logging'
require_relative './chromedriver_setup'

module Utils
  module GoogleSession
    extend ::Utils::Logging

    @cookie_header = nil
    @driver = nil
    @initialized = false
    @mutex = Mutex.new  # Thread synchronization mutex
    
    # Persist captured cookie header so subsequent processes or runs can reuse
    COOKIE_CACHE_PATH = ENV.fetch('GOOGLE_COOKIE_FILE', File.expand_path('~/.google_cookies.json')).freeze
    COOKIE_TTL = (ENV['GOOGLE_COOKIE_TTL'] || '28800').to_i # 8 hours default

    GOOGLE_ROOT_URL = ENV.fetch('GOOGLE_ROOT_URL', 'https://accounts.google.com/ServiceLogin').freeze
    WAIT_TIMEOUT = (ENV['GOOGLE_LOGIN_TIMEOUT'] || '300').to_i
    SELENIUM_DOWNLOAD_DIR = File.expand_path('../../tmp/selenium_browser_downloads', __dir__)

    class << self
      attr_reader :driver, :cookie_header

      # Main driver method - simple and consistent with BasecampSession
      def driver
        # Use synchronization to prevent concurrent access
        @mutex.synchronize do
          ensure_cookies! unless @driver && @initialized
        end
        @driver
      end

      # Ensures we have cookies and a driver - core method 
      def ensure_cookies!
        # If we already have valid cookies, just return them
        # This is inside a mutex-controlled section, so no race conditions
        return @cookie_header if @cookie_header && cached_cookies_valid?

        # Try to load cached cookies first
        if load_cookies
          log "📋 Using cached Google cookies"
          return @cookie_header
        end

        # Setup the browser
        setup_browser
        
        # Login to Google and get cookies
        login_and_get_cookies
        
        # Return the cookie header
        @cookie_header
      end

      # Navigate to a URL using the browser
      # This is the most critical function to protect with synchronization
      def navigate_to(url)
        log "🔍 Thread #{Thread.current.object_id} attempting to navigate browser"
        @mutex.synchronize do
          log "🔒 Thread #{Thread.current.object_id} acquired browser lock"
          # Use @driver directly to avoid nested mutex deadlock (driver method also locks @mutex)
          @driver.navigate.to(url)
          # Add short sleep to ensure page has started loading
          sleep 0.5
          log "✅ Thread #{Thread.current.object_id} navigation complete"
        end
      end
      
      # Get the cookie header for authentication
      def authorize_cookies
        @mutex.synchronize do
          ensure_cookies!
        end
        @cookie_header
      end
      
      private
      
      def setup_browser
        # Initialize chromedriver
        Utils::ChromedriverSetup.ensure_driver_available
        require 'selenium-webdriver'
        
        # Suppress Selenium WebDriver debug logs
        Selenium::WebDriver.logger.level = :warn # Change to :error for even less output
        
        # Create Chrome options
        options = Selenium::WebDriver::Chrome::Options.new
        profile_dir = ENV['GOOGLE_CHROME_PROFILE_DIR'] || File.expand_path('~/.google_chrome')
        options.add_argument("--user-data-dir=#{profile_dir}")
        options.add_argument('--profile-directory=Default')
        options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'

      # Configure custom download directory for Selenium browser
      FileUtils.mkdir_p(SELENIUM_DOWNLOAD_DIR) unless Dir.exist?(SELENIUM_DOWNLOAD_DIR)
      prefs = {
        'download.default_directory' => SELENIUM_DOWNLOAD_DIR,
        'download.prompt_for_download' => false,
        'directory_upgrade' => true
      }
      options.add_preference(:download, prefs)
        
        # Suppress Chrome driver logging
        options.add_argument('--log-level=3') # fatal
        options.add_argument('--silent')
        
        # Launch the browser
        @driver = Selenium::WebDriver.for(:chrome, options: options)
        log "🔐 Google browser session started"
      rescue => e
        log "⚠️ Error setting up browser: #{e.message}"
        nil
      end
      
      def login_and_get_cookies
        # Bail out if browser failed to start
        unless @driver
          log "⛔ Google browser driver not initialised — aborting cookie fetch"
          return false
        end

        # Navigate to Google login
        @driver.navigate.to(GOOGLE_ROOT_URL)
        log "🔑 Navigating to Google login"
        
        # Wait for login to complete
        Timeout.timeout(WAIT_TIMEOUT) do
          until @driver.title !~ /Sign in/i && @driver.current_url !~ /ServiceLogin/i
            sleep 1
          end
        end
        
        # Get cookies from browser
        cookies = @driver.manage.all_cookies
        domain_cookies = cookies.select { |c| c[:domain] =~ /google/ }
        
        if domain_cookies.empty?
          log "⛔ No Google cookies found, login may have failed"
        else
          log "✅ Google login confirmed. #{domain_cookies.count} cookies found."
          cookie_string = domain_cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
          @cookie_header = "Cookie: #{cookie_string}"
          save_cookies
          @initialized = true
        end
      rescue Timeout::Error
        log "⚠️ Timeout waiting for Google login"
        false
      end

      def cached_cookies_valid?
        return false unless @cookie_header
        return true if ENV['IGNORE_COOKIE_TTL'] == '1'

        cache_file = COOKIE_CACHE_PATH
        return false unless File.exist?(cache_file)

        # Check whether file is newer than TTL
        cache_age = Time.now.to_i - File.mtime(cache_file).to_i
        return cache_age < COOKIE_TTL
      rescue => e
        log "⚠️ Error checking cookie validity: #{e.message}"
        false
      end

      def save_cookies
        return unless @cookie_header

        cache_dir = File.dirname(COOKIE_CACHE_PATH)
        Dir.mkdir(cache_dir) unless Dir.exist?(cache_dir)

        File.write(COOKIE_CACHE_PATH, JSON.generate(cookie_header: @cookie_header))
        log "💾 Saved cookies to #{COOKIE_CACHE_PATH}"
      rescue => e
        log "⚠️ Error saving cookies: #{e.message}"
      end

      def load_cookies
        return false unless File.exist?(COOKIE_CACHE_PATH)

        if cached_cookies_valid?
          json = JSON.parse(File.read(COOKIE_CACHE_PATH))
          @cookie_header = json['cookie_header']
          log "📋 Loaded cookies from #{COOKIE_CACHE_PATH}"
          return true
        end

        false
      rescue => e
        log "⚠️ Error loading cookies: #{e.message}"
        false
      end
    end
  end
end
