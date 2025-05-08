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
require_relative './logging'
require_relative './chromedriver_setup'

module Utils
  module BasecampSession
    extend ::Utils::Logging

    @cookie_header = nil
    @driver = nil

    BC_ROOT_URL = ENV.fetch('BASECAMP_ROOT_URL', 'https://launchpad.37signals.com/signin').freeze
    WAIT_TIMEOUT = (ENV['BASECAMP_LOGIN_TIMEOUT'] || '300').to_i

    @prompted = false
    class << self
      attr_reader :driver, :cookie_header

      def ensure_cookies!
        return @cookie_header if @cookie_header
        return @cookie_header if @prompted
        @prompted = true

        # Ensure chromedriver ready (no-op if already done)
        Utils::ChromedriverSetup.ensure_driver_available

        require 'selenium-webdriver'

        options = Selenium::WebDriver::Chrome::Options.new
        # Reuse a persistent profile dir so cookies survive across runs
        profile_dir = ENV['BC_CHROME_PROFILE_DIR'] || File.expand_path('~/.bc_chrome')
        options.add_argument("--user-data-dir=#{profile_dir}")
        options.add_argument('--profile-directory=Default')
        options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'

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

        # Ensure browser closes when script exits
        at_exit { shutdown! }
      rescue => e
        error "❌ Basecamp session setup failed: #{e.class}: #{e.message}"
        exit(1)
        nil
      end

      def shutdown!
        @driver&.quit
        @driver = nil
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
