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
require_relative '../config' # For global configuration constants

module Utils
  module GoogleSession
    extend ::Utils::Logging

    @cookie_header = nil
    @driver = nil
    @initialized = false
    @mutex = Mutex.new  # Thread synchronization mutex
    @shutdown_hook_set = false
    # Watchdog State Variables
    @current_operation_id = nil
    @consecutive_operation_failures = 0
    @restarts_for_current_operation = 0
    @global_driver_restarts = 0

    # MAX_DRIVER_RESTARTS = ENV.fetch('SELENIUM_MAX_RESTARTS', 2).to_i # Legacy, use Config::SELENIUM_MAX_GLOBAL_RESTARTS
    
    # Persist captured cookie header so subsequent processes or runs can reuse
    COOKIE_CACHE_PATH = ENV.fetch('GOOGLE_COOKIE_FILE', File.expand_path('~/.google_cookies.json')).freeze
    COOKIE_TTL = (ENV['GOOGLE_COOKIE_TTL'] || '28800').to_i # 8 hours default

    GOOGLE_ROOT_URL = ENV.fetch('GOOGLE_ROOT_URL', 'https://accounts.google.com/ServiceLogin').freeze
    WAIT_TIMEOUT = (ENV['GOOGLE_LOGIN_TIMEOUT'] || '300').to_i
    SELENIUM_DOWNLOAD_DIR = File.expand_path('../../tmp/selenium_browser_downloads', __dir__)

  # Custom error for initialization failures
  class GoogleSessionInitializationError < StandardError; end
  # Custom error for when an operation exceeds its restart attempts
  class SeleniumOperationMaxRestartsError < StandardError; end
  # Custom error for when global Selenium restarts are exceeded
  class SeleniumGlobalMaxRestartsError < StandardError; end

    class << self
      attr_reader :driver, :cookie_header

      # Main driver method - simple and consistent with BasecampSession
      def driver
        # ensure_driver_available! handles its own synchronization.
        ensure_driver_available!
        @driver # Return the driver instance variable, which ensure_driver_available! will set/update.
      end

      # Ensures a live driver is available, respecting global restart limits.
      # Called by execute_operation within a mutex.
      def ensure_driver_available!
        # Fast path: driver already exists, is initialized, and cookies are considered valid.
        # The cookie_header check ensures login was successful previously.
        if @driver && @initialized && @cookie_header && cached_cookies_valid?
          # log "✅ Driver and valid cookies already available."
          return
        end

        if @global_driver_restarts >= SELENIUM_MAX_GLOBAL_RESTARTS
          error "🚫 Watchdog: Global Selenium driver restart limit (#{SELENIUM_MAX_GLOBAL_RESTARTS}) reached. Cannot initialize driver."
          _shutdown_driver_state # Ensure any remnants are cleaned up
          raise SeleniumGlobalMaxRestartsError, "Global Selenium driver restart limit reached. Last known operation: #{@current_operation_id}"
        end
        
        log "ℹ️ Watchdog: Driver not available or needs re-initialization. Attempting (Global restart ##{@global_driver_restarts + 1} of #{SELENIUM_MAX_GLOBAL_RESTARTS})."
        
        # Attempt to load cookies from cache if this isn't a forced re-initialization after a failure.
        # If cookies are loaded and valid, we might not need a full browser login, but still need a driver instance.
        # However, for simplicity in the watchdog flow, a restart implies getting fresh cookies via browser.
        # The `_initialize_driver_and_cookies` handles its own cookie logic including cache checks if `is_restart` is false.
        # When called from here (typically after a failure or first time), we force `is_restart: true` to get fresh state.
        begin
          _initialize_driver_and_cookies(is_restart: true) # Force re-login for a restart scenario
          log "✅ Watchdog: Driver initialized successfully. Global restarts: #{@global_driver_restarts + 1}."
          @global_driver_restarts += 1 # Increment *after* successful initialization
        rescue => e
          error "❌ Watchdog: Google session setup failed during ensure_driver_available!: #{e.class}: #{e.message}"
          # _shutdown_driver_state is likely called within _initialize_driver_and_cookies on failure paths
          raise GoogleSessionInitializationError, "Failed to initialize Google session for watchdog: #{e.message}" # Re-raise to be caught by execute_operation
        end

        unless @shutdown_hook_set
          at_exit { shutdown! } # shutdown! is the public method with mutex
          @shutdown_hook_set = true
        end
      end

      # Old ensure_cookies! is replaced by ensure_driver_available! and execute_operation logic.
      # def ensure_cookies!(is_part_of_restart: false) ... end

      # Executes a given Selenium operation with watchdog capabilities for retries and driver restarts.
      # operation_id: A unique identifier for the operation (e.g., URL being processed).
      # &block: A block of code that takes the Selenium driver as an argument and performs actions.
      def execute_operation(operation_id, &block)
        @mutex.synchronize do
          # If the operation ID has changed, reset per-operation counters
          if @current_operation_id != operation_id
            log "ℹ️ Watchdog: New operation: '#{operation_id}'. Previous: '#{@current_operation_id}'. Resetting per-operation failure/restart counts."
            @current_operation_id = operation_id
            @consecutive_operation_failures = 0
            @restarts_for_current_operation = 0
          end

          loop do # This loop handles retries involving driver restarts for the current operation
            begin
              ensure_driver_available! # Ensures driver is ready, respecting global limits

              # Yield to the block that performs the actual Selenium actions
              result = block.call(@driver)
              
              # If successful, reset consecutive failures for this operation and return
              @consecutive_operation_failures = 0
              return result

            rescue Selenium::WebDriver::Error::WebDriverError, Net::ReadTimeout, GoogleSessionInitializationError => e # Catch Selenium, network, or our own init errors
              @consecutive_operation_failures += 1
              error "❌ Watchdog: Selenium operation failure ##{@consecutive_operation_failures} for '#{operation_id}': #{e.class} - #{e.message}"
              e.backtrace.first(5).each { |line| debug "    #{line}" }

              if @consecutive_operation_failures >= SELENIUM_CONSECUTIVE_OPERATION_FAILURES_THRESHOLD
                warn "⚠️ Watchdog: Consecutive failure threshold (#{SELENIUM_CONSECUTIVE_OPERATION_FAILURES_THRESHOLD}) reached for '#{operation_id}'."
                
                if @restarts_for_current_operation >= SELENIUM_RESTARTS_PER_OPERATION_LIMIT
                  error "🚫 Watchdog: Max restarts per operation (#{SELENIUM_RESTARTS_PER_OPERATION_LIMIT}) reached for '#{operation_id}'. Giving up on this operation."
                  raise SeleniumOperationMaxRestartsError, "Max restarts reached for operation '#{operation_id}'. Last error: #{e.message}"
                end

                log "🔄 Watchdog: Attempting driver restart for operation '#{operation_id}' (Restart ##{@restarts_for_current_operation + 1} of #{SELENIUM_RESTARTS_PER_OPERATION_LIMIT} for this op)."
                _shutdown_driver_state # Quit current driver before attempting re-initialization
                @restarts_for_current_operation += 1
                @consecutive_operation_failures = 0 # Reset for the new driver session attempt
                # The loop will continue, and ensure_driver_available! will be called again.
              else
                # Consecutive failures below threshold. Re-raise the original error.
                # This allows any more specific, immediate retry logic (e.g., for a 403) to act before a driver restart.
                raise
              end
            # Note: SeleniumGlobalMaxRestartsError from ensure_driver_available! will propagate out of this method if raised.
            end
          end
        end
      end

      # Attempts to initialize the Google session driver if not already done.
      # Called at startup to prime the session.
      def prime_session!
        log "ℹ️ Watchdog: Priming Google session (ensuring driver is available)..."
        @mutex.synchronize do
          ensure_driver_available! # This will attempt to initialize if needed, respecting global limits.
        end
        log "✅ Watchdog: Google session primed. Driver should be ready if no errors occurred."
      rescue SeleniumGlobalMaxRestartsError => e
        error "🚫 Watchdog: Global Selenium restart limit (of #{SELENIUM_MAX_GLOBAL_RESTARTS}) reached during startup priming. Google features will likely fail. Error: #{e.message}"
        # Script may continue, but Google operations will fail if they rely on this.
      rescue GoogleSessionInitializationError => e
        error "❌ Watchdog: Google session setup failed during startup priming: #{e.class}: #{e.message}"
        # Script may continue, subsequent operations will likely trigger this again.
      rescue => e # Catch any other unexpected error during priming
        error "💥 Unexpected error during Google session priming: #{e.class}: #{e.message}"
        e.backtrace.first(5).each { |line| debug "    #{line}" }
      end

      def shutdown!
        @mutex.synchronize do
          _shutdown_driver_state
        end
      rescue => e
        warn "⚠️ Error closing Google browser during shutdown!: #{e.message}"
      end

      # Navigate to a URL using the browser
      # This is the most critical function to protect with synchronization
      def navigate_to(url)
        @mutex.synchronize do # Ensure thread safety for the whole operation including retries
          # Ensure we have a driver to start with. Pass true for is_part_of_restart if @driver is nil, 
          # implying a potential prior failure or first-time call within a retry loop.
          ensure_cookies!(is_part_of_restart: @driver.nil?) unless @driver && @initialized
          
          loop do # This loop is for retrying the 'navigate' operation after a driver restart
            raise GoogleSessionInitializationError, "Google driver not available. Cannot navigate." unless @driver && @initialized
            
            log "🔍 Navigating to: #{url} (Restarts: #{@driver_restart_count}/#{MAX_DRIVER_RESTARTS})"
            begin
              @driver.navigate.to(url)
              sleep 0.5 # Existing short sleep
              log "✅ Navigation to #{url} complete."
              return # Successful navigation, exit method
            rescue Selenium::WebDriver::Error::TimeoutError, Selenium::WebDriver::Error::WebDriverError => e
              error "💥 Selenium operation failed in GoogleSession navigate_to: #{e.class} - #{e.message}."
              if _attempt_driver_restart(e)
                log "✅ Driver restarted successfully (GoogleSession). Retrying navigation to #{url}..."
                next # Retry the loop (which means retrying the navigation with the new driver)
              else
                error "🚫 Failed to recover Google Selenium session for navigating to #{url}. Raising original error."
                raise e # Re-raise the original Selenium exception if restart fails or max attempts reached
              end
            end
          end # loop for retrying navigation
        end # mutex
      end
      
      # Get the cookie header for authentication
      def authorize_cookies
        @mutex.synchronize do
          ensure_cookies!
        end
        @cookie_header
      end
      
      private

      def _shutdown_driver_state
        if @driver
          log "🔌 Shutting down Google Selenium driver..."
          @driver.quit rescue warn "⚠️ Error quitting Google driver: #{$!.message}"
        end
        @driver = nil
        @cookie_header = nil # Clear cookies as they are tied to the session
        @initialized = false
        # Do not reset @driver_restart_count here, it's managed by _initialize_driver_and_cookies and _attempt_driver_restart
        log " Google driver state cleared."
      end

      def _initialize_driver_and_cookies(is_restart: false)
        log "🛠️ Initializing Google Selenium driver and cookies...#{is_restart ? ' (As part of restart)' : ''}"
        
        _shutdown_driver_state if @driver # Ensure any existing driver is gone before creating a new one

        setup_browser # Existing method to configure and launch Chrome. Should raise on error or ensure @driver is set.
        raise "Failed to setup browser instance in _initialize_driver_and_cookies." unless @driver

        login_successful = login_and_get_cookies # Existing method. Should return true/false or raise.
        raise "Failed to login to Google and get cookies in _initialize_driver_and_cookies." unless login_successful

        @initialized = true
        @driver_restart_count = 0 # Reset on any successful *full* initialization sequence
        log "✅ Google Selenium session initialized successfully. Driver restart count reset."
        @cookie_header
      rescue Selenium::WebDriver::Error::WebDriverError, Timeout::Error, StandardError => e
        _shutdown_driver_state # Cleanup on any failure during init
        error "❌ Error during Google driver initialization sequence: #{e.class} - #{e.message}"
        raise # Re-raise the caught error to be handled by caller
      end

      def _attempt_driver_restart(original_exception)
        if @driver_restart_count < MAX_DRIVER_RESTARTS
          @driver_restart_count += 1
          warn "🔥 Attempting Google Selenium driver restart (attempt ##{@driver_restart_count} of #{MAX_DRIVER_RESTARTS}) due to: #{original_exception.class}."
          
          begin
            _initialize_driver_and_cookies(is_restart: true) # Force fresh init, no cache usage internally for restart path
            log "✅ Google Selenium driver re-initialized successfully after #{original_exception.class}."
            return true # Signal success for retrying the operation
          rescue => init_error
            error "❌ Failed to re-initialize Google Selenium driver during restart attempt ##{@driver_restart_count}: #{init_error.class} - #{init_error.message}"
          end
        else
          error "🚫 Max driver restarts (#{MAX_DRIVER_RESTARTS}) reached for Google session. Not attempting further restarts for this error: #{original_exception.class}."
        end
        false # Signal failure to restart or max attempts reached
      end
      
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
        raise "Google browser driver not initialised — aborting cookie fetch." unless @driver

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
          # Ensure @initialized is false and return false or raise to indicate failure
          @initialized = false
          raise "No Google cookies found after login attempt."
        else
          log "✅ Google login confirmed. #{domain_cookies.count} cookies found."
          cookie_string = domain_cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
          @cookie_header = "Cookie: #{cookie_string}"
          save_cookies
          @initialized = true # This indicates a successful login and cookie capture
          return true # Explicitly return true on success
        end
      rescue Timeout::Error
        log "⚠️ Timeout waiting for Google login"
        @initialized = false # Ensure state reflects failure
        raise # Re-raise Timeout::Error to be caught by _initialize_driver_and_cookies
      rescue => e # Catch other potential errors during Selenium interaction
        log "⚠️ Error during Google login/cookie fetch: #{e.class} - #{e.message}"
        @initialized = false # Ensure state reflects failure
        raise # Re-raise to be caught by _initialize_driver_and_cookies
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
