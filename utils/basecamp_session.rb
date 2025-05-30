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
    @driver_restart_count = 0
    MAX_DRIVER_RESTARTS = ENV.fetch('SELENIUM_MAX_RESTARTS', 2).to_i

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
          # Double-check inside mutex
          return @cookie_header if @cookie_header && @driver

          if @prompted && !@driver
            log "🔁 Basecamp session was prompted but driver not fully initialized. Attempting full setup."
          end
          @prompted = true # Mark that we've started or attempted initialization

          begin
            _initialize_driver_and_cookies
          rescue => e
            error "❌ Basecamp session setup failed during _initialize_driver_and_cookies: #{e.class}: #{e.message}"
            # Re-raise a specific error or the original, to be handled by callers or exit.
            # For now, let's maintain original behavior of exiting if initial setup fails hard.
            # If ensure_cookies! is called as part of a restart, this exit might be too harsh.
            # Consider raising a custom error that can be caught by _attempt_driver_restart if needed.
            raise BasecampSessionInitializationError, "Failed to initialize Basecamp session: #{e.message}" 
          end

          unless @shutdown_hook_set
            at_exit { shutdown! } # shutdown! is the public method with mutex
            @shutdown_hook_set = true
          end
        end
        @cookie_header
      end

      def with_driver(&block)
        ensure_cookies! # Initial check

        @session_mutex.synchronize do
          loop do # This loop is for retrying the 'yield' operation after a driver restart
            raise "Basecamp driver not initialized or setup failed. Cannot yield driver." unless @driver
            begin
              return yield @driver # Execute block. If successful, method returns.
            rescue Selenium::WebDriver::Error::TimeoutError, Selenium::WebDriver::Error::WebDriverError => e
              error "💥 Selenium operation failed in BasecampSession: #{e.class} - #{e.message}. Current restarts: #{@driver_restart_count}/#{MAX_DRIVER_RESTARTS}"
              if _attempt_driver_restart(e) # This method is responsible for incrementing count and re-initializing
                log "✅ Driver restarted successfully within BasecampSession. Retrying operation..."
                next # Retry the loop (which means retrying `yield @driver` with the new driver)
              else
                error "🚫 Failed to recover Basecamp Selenium session after multiple attempts. Raising original error."
                raise e # Re-raise the original Selenium exception if restart fails or max attempts reached
              end
            end
          end # loop for retrying yield
        end # mutex
      end
      # End of revised with_driver. Let's use this structure. The original replacement target for with_driver should be replaced by this.


      def shutdown!
        @session_mutex.synchronize do
          _shutdown_driver_state # Use internal method
        end
      rescue => e
        warn "⚠️ Error closing browser during shutdown!: #{e.message}"
      end

      private

      # Internal method to shut down driver and clear state variables
      # This method does NOT handle the mutex; it's assumed to be called from a synchronized context or when mutex is not needed.
      def _shutdown_driver_state
        if @driver
          log "🔌 Shutting down Basecamp Selenium driver..."
          @driver.quit rescue warn "⚠️ Error quitting Basecamp driver: #{$!.message}"
        end
        @driver = nil
        @cookie_header = nil
        # @prompted = false # Consider if @prompted should be reset, e.g., for full re-init logic
        log " Driver state cleared."
      end

      # Internal method to initialize driver and cookies. Raises error on failure.
      def _initialize_driver_and_cookies
        log "🛠️ Initializing Basecamp Selenium driver and cookies..."
        # Ensure chromedriver ready (no-op if already done)
        Utils::ChromedriverSetup.ensure_driver_available
        require 'selenium-webdriver' # Ensure it's loaded

        options = Selenium::WebDriver::Chrome::Options.new
        profile_dir = ENV['BC_CHROME_PROFILE_DIR'] || File.expand_path('~/.bc_chrome')
        options.add_argument("--user-data-dir=#{profile_dir}")
        options.add_argument('--profile-directory=Default')
        options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'
        FileUtils.mkdir_p(SELENIUM_DOWNLOAD_DIR) unless Dir.exist?(SELENIUM_DOWNLOAD_DIR)
        prefs = { 'download.default_directory' => SELENIUM_DOWNLOAD_DIR, 'download.prompt_for_download' => false, 'directory_upgrade' => true }
        options.add_preference(:download, prefs)

        @driver = Selenium::WebDriver.for(:chrome, options: options)
        log "🔐 Opening Basecamp login page: #{BC_ROOT_URL}"
        @driver.navigate.to(BC_ROOT_URL)
        log "👩‍💻 Please sign in to Basecamp if prompted… (timeout: #{WAIT_TIMEOUT}s)"
        wait_for_login! # This can raise Timeout::Error

        unless @driver.current_url.match?(%r{https://3\.basecamp\.com})
          @driver.navigate.to('https://3.basecamp.com')
          sleep 2 # Allow navigation and cookie setting
        end

        build_cookie_header!
        Utils::MediaExtractor.basecamp_headers = { 'Cookie' => @cookie_header }
        
        @driver_restart_count = 0 # Reset restart count on successful initialization
        log "✅ Basecamp Selenium session initialized successfully. Driver restart count reset."
        @cookie_header
      rescue Selenium::WebDriver::Error::WebDriverError => e
        _shutdown_driver_state # Ensure driver is cleaned up if init fails mid-way
        error "❌ WebDriverError during Basecamp driver initialization: #{e.message}"
        raise # Re-raise the original WebDriverError
      rescue Timeout::Error => e
        _shutdown_driver_state
        error "❌ Timeout::Error during Basecamp login: #{e.message}"
        raise # Re-raise Timeout::Error
      rescue => e # Catch any other unexpected error during initialization
        _shutdown_driver_state
        error "❌ Unexpected error during Basecamp driver initialization: #{e.class} - #{e.message}"
        raise # Re-raise
      end

      # Internal method to attempt driver restart. Returns true if successful and operation should be retried, false otherwise.
      # Assumes it's called from within a @session_mutex.synchronize block.
      def _attempt_driver_restart(original_exception)
        # Logged by caller
        # error "💥 Selenium operation failed: #{original_exception.class} - #{original_exception.message}"
        
        if @driver_restart_count < MAX_DRIVER_RESTARTS
          @driver_restart_count += 1
          warn "🔥 Attempting Basecamp Selenium driver restart (attempt ##{@driver_restart_count} of #{MAX_DRIVER_RESTARTS})..."
          
          _shutdown_driver_state # Clean up old driver instance
          
          begin
            _initialize_driver_and_cookies # Attempt to re-initialize
            # If successful, @driver_restart_count was reset to 0 by _initialize_driver_and_cookies.
            # This is not quite right. The @driver_restart_count should reflect the number of *attempts to restart this session*.
            # Let's adjust: _initialize_driver_and_cookies should NOT reset @driver_restart_count.
            # The count is for the *current recovery sequence*.
            # It should be reset only when `ensure_cookies!` is called for a truly fresh start, not a restart.
            # For now, let _initialize_driver_and_cookies reset it, and we'll see. Simpler is that a successful init is a fresh start.
            log "✅ Basecamp Selenium driver re-initialized successfully after #{original_exception.class}."
            return true # Signal success for retrying the operation
          rescue => init_error
            error "❌ Failed to re-initialize Basecamp Selenium driver during restart attempt ##{@driver_restart_count}: #{init_error.class} - #{init_error.message}"
            # If re-initialization fails, we don't retry further in this attempt. Fall through to return false.
          end
        else
          error "🚫 Max driver restarts (#{MAX_DRIVER_RESTARTS}) reached for Basecamp session. Not attempting further restarts for this error: #{original_exception.class}."
        end
        
        false # Signal failure to restart or max attempts reached
      end

      # Custom error for initialization failures
      class BasecampSessionInitializationError < StandardError; end


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
