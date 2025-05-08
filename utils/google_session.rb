# utils/google_session.rb
# Manages a reusable Selenium session for Google authentication.
# Provides cookies for authenticated requests to googleusercontent URLs.

require 'timeout'
require_relative './logging'
require_relative './chromedriver_setup'

module Utils
  module GoogleSession
    extend ::Utils::Logging

    @cookie_header = nil
    @driver = nil

    GOOGLE_ROOT_URL = ENV.fetch('GOOGLE_ROOT_URL', 'https://accounts.google.com/ServiceLogin').freeze
    WAIT_TIMEOUT = (ENV['GOOGLE_LOGIN_TIMEOUT'] || '300').to_i

    class << self
      attr_reader :driver, :cookie_header

      def ensure_cookies!
        # If we already have cookies and they appear valid, reuse.
        return @cookie_header if @cookie_header && authenticated?

        Utils::ChromedriverSetup.ensure_driver_available
        require 'selenium-webdriver'
        require 'tmpdir'

        begin
          options = Selenium::WebDriver::Chrome::Options.new
          profile_dir = ENV['GOOGLE_CHROME_PROFILE_DIR'] || File.expand_path('~/.google_chrome')
          options.add_argument("--user-data-dir=#{profile_dir}")
          options.add_argument('--profile-directory=Default')
          options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'
          @driver = Selenium::WebDriver.for(:chrome, options: options)
        rescue Selenium::WebDriver::Error::SessionNotCreatedError, Selenium::WebDriver::Error::UnknownError => e
          warn "⚠️ Persistent Chrome profile locked or unavailable: #{e.class}: #{e.message}"
          temp_profile_dir = Dir.mktmpdir('google_chrome_profile')
          options = Selenium::WebDriver::Chrome::Options.new
          options.add_argument("--user-data-dir=#{temp_profile_dir}")
          options.add_argument('--profile-directory=Default')
          options.add_argument('--headless=new') if ENV['HEADLESS'] == '1'
          @driver = Selenium::WebDriver.for(:chrome, options: options)
          log "🔄 Using temporary Chrome profile for this session. You may need to log in again."
        end

        log "🔐 Opening Google login page: #{GOOGLE_ROOT_URL}"
        @driver.navigate.to(GOOGLE_ROOT_URL)

        log "👩‍💻 Please sign in to Google if prompted… (timeout: #{WAIT_TIMEOUT}s)"
        wait_for_login!

        build_cookie_header!
        log "✅ Google cookies captured for googleusercontent access"
        @cookie_header

        at_exit { shutdown! }
      rescue => e
        error "❌ Google session setup failed: #{e.class}: #{e.message}"
        exit(1)
        nil
      end

      def shutdown!
        @driver&.quit
        @driver = nil
      rescue => e
        warn "⚠️ Error closing Google browser: #{e.message}"
      end

      private

      def authenticated?
        return false unless @driver
        url = @driver.current_url
        on_login_screen = url.include?('ServiceLogin') || url.include?('signin')
        session_cookie = @driver.manage.all_cookies.any? { |c| c[:domain].include?('google.') && c[:name] == 'SID' }
        session_cookie && !on_login_screen
      end

      def wait_for_login!
        Timeout.timeout(WAIT_TIMEOUT) do
          sleep 1 until authenticated?
        end
      rescue Timeout::Error
        warn "⚠️ Google login timeout after #{WAIT_TIMEOUT}s; continuing with whatever cookies were set…"
      end

      def build_cookie_header!
        cookies = @driver.manage.all_cookies.select { |c| c[:domain].include?('google.') }
        @cookie_header = cookies.map { |c| "#{c[:name]}=#{c[:value]}" }.join('; ')
      end
    end
  end
end
