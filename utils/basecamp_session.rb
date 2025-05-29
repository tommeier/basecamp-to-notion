# utils/basecamp_session.rb
# Manages a single, reusable Selenium session for Basecamp authentication.
# It captures the session cookies once and provides them to Net::HTTP requests
# via Utils::MediaExtractor.basecamp_headers.
#
# Usage:
#   Utils::BasecampSession.ensure_cookies!
#   # subsequent requests can use Utils::MediaExtractor.basecamp_headers
#
# The session remains open for the lifetime of the script so that cookies stay
# fresh. On exit, the driver is quit automatically.

require 'timeout'
require 'thread' # For Mutex
require 'fileutils' # For creating directories
require_relative './logging'
require_relative './chromedriver_setup'

module Utils
  module BasecampSession
    extend ::Utils::Logging

    @cookie_header = nil
    @driver = nil
    @session_mutex = Mutex.new
    @shutdown_hook_set = false # To ensure at_exit is only set once

    BC_ROOT_URL = ENV.fetch('BASECAMP_ROOT_URL', 'https://launchpad.37signals.com/signin').freeze
    WAIT_TIMEOUT = (ENV['BASECAMP_LOGIN_TIMEOUT'] || '300').to_i
    SELENIUM_DOWNLOAD_DIR = File.expand_path('../../tmp/selenium_browser_downloads', __dir__)

    @prompted = false
    class << self
      attr_reader :cookie_header # driver will be accessed via with_driver

      def driver
        # Direct access to @driver is discouraged; use with_driver for safety.
        # This getter is kept for minimal disruption if some internal/legacy code still uses it,
        # but it should be used only within a @session_mutex.synchronize block.
        @driver
      end

      def ensure_cookies!
        # Fast path: already initialized and driver is present
        return @cookie_header if @cookie_header && @driver

        @session_mutex.synchronize do
          # Double-check inside mutex: another thread might have completed initialization
          return @cookie_header if @cookie_header && @driver

          # If @driver is nil, we are the first thread to initialize or re-initialize.
          # @prompted helps to avoid re-showing user prompts if initialization was partial or failed before.
          # However, the main gate is @driver being nil.

          if @prompted && !@driver
            log "🔁 Basecamp session was prompted but driver not fully initialized. Retrying setup."
          end

          @prompted = true # Indicate that initialization process has started/been attempted

        # Ensure chromedriver ready (no-op if already done)
        Utils::ChromedriverSetup.ensure_driver_available

        require 'selenium-webdriver'

        options = Selenium::WebDriver::Chrome::Options.new
        # Reuse a persistent profile dir so cookies survive across runs
        profile_dir = ENV['BC_CHROME_PROFILE_DIR'] || File.expand_path('~/.bc_chrome')
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

        @driver = Selenium::WebDriver.for(:chrome, options: options)

        log "🔐 Opening Basecamp login page: #{BC_ROOT_URL}"
        @driver.navigate.to(BC_ROOT_URL)

        log "👩‍💻 Please sign in to Basecamp if prompted… (timeout: #{WAIT_TIMEOUT}s)"
        wait_for_login!

        # Ensure we hit the Basecamp 3 domain so session cookies are set
        unless @driver.current_url.match?(%r{https://3\.basecamp\.com})
          @driver.navigate.to('https://3.basecamp.com')
          sleep 2
        end

        build_cookie_header!
        Utils::MediaExtractor.basecamp_headers = { 'Cookie' => @cookie_header }
        log "✅ Basecamp cookies captured & applied to MediaExtractor"
        @cookie_header

          # Ensure browser closes when script exits - only set this hook once
          unless @shutdown_hook_set
            at_exit { shutdown! }
            @shutdown_hook_set = true
          end
        end # End of @session_mutex.synchronize block for initialization
        @cookie_header # Return cookie_header, which should be set if successful
      rescue => e
        error "❌ Basecamp session setup failed: #{e.class}: #{e.message}"
        exit(1)
        nil
      end

      def with_driver(&block)
        ensure_cookies! # Ensure session is initialized
        @session_mutex.synchronize do
          raise "Basecamp driver not initialized or setup failed. Cannot yield driver." unless @driver
          yield @driver
        end
      end

      def shutdown!
        @session_mutex.synchronize do
          @driver&.quit
          @driver = nil
        end
      rescue => e
        warn "⚠️ Error closing browser: #{e.message}"
      end

      private

      def authenticated?
        url = @driver.current_url
        on_login_screen = url.include?('signin') || url.include?('login') || url.include?('two-factor')
        session_cookie = @driver.manage.all_cookies.any? { |c| c[:name].match?(/bc3_session|_session/i) }
        session_cookie && !on_login_screen
      end

      def wait_for_login!
        Timeout.timeout(WAIT_TIMEOUT) do
          sleep 1 until authenticated?
        end
      rescue Timeout::Error
        warn "⚠️ Login timeout after #{WAIT_TIMEOUT}s; continuing with whatever cookies were set…"
      end

      def build_cookie_header!
        cookies = @driver.manage.all_cookies.select { |c| c[:domain].include?('basecamp.com') }
        @cookie_header = cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
      end
    end
  end
end
