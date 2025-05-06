# utils/chromedriver_setup.rb
#
# Ensures a functional chromedriver binary is available for Selenium usage.
# Works cross-platform; on macOS it also removes the quarantine attribute that
# blocks execution when the binary is downloaded.
#
# From Selenium 4.11+ the Selenium Manager binary handles driver download
# automatically, so we no longer depend on the `webdrivers` gem. This helper
# now focuses only on removing Gatekeeper quarantine (macOS) and ensuring a
# discoverable path to `chromedriver` when possible.
#
# Set the env var `NO_CHROMEDRIVER=1` to skip driver setup entirely.
# -----------------------------------------------------------------------------

require 'rbconfig'
require 'shellwords'
require_relative './logging'

module Utils
  module ChromedriverSetup
    extend ::Utils::Logging

    def self.ensure_driver_available
      return if ENV['NO_CHROMEDRIVER'] == '1'

      begin
        # Try to load selenium first; if missing, bail early.
        require 'selenium-webdriver'
      rescue LoadError
        warn "⚠️ 'selenium-webdriver' gem missing — Chromedriver setup skipped"
        return
      end

      # -------------------------------
      # Locate chromedriver binary path
      # -------------------------------
      driver_path = nil

      # Attempt to read existing setting if API allows it
      begin
        if Selenium::WebDriver.const_defined?(:Chrome) && Selenium::WebDriver::Chrome.respond_to?(:driver_path)
          driver_path = Selenium::WebDriver::Chrome.driver_path
        elsif Selenium::WebDriver.const_defined?(:Chrome) && defined?(Selenium::WebDriver::Chrome::Service) && Selenium::WebDriver::Chrome::Service.respond_to?(:driver_path)
          driver_path = Selenium::WebDriver::Chrome::Service.driver_path
        end
      rescue NoMethodError
        driver_path = nil
      end

      driver_path = nil if driver_path.to_s.empty?

      # Fallback: search in PATH
      if driver_path.nil?
        detected = `which chromedriver`.chomp
        driver_path = detected unless detected.empty?
      end

      if driver_path && File.exist?(driver_path)
        # Remove macOS quarantine attribute so the binary is executable
        if RbConfig::CONFIG['host_os'] =~ /darwin/
          system('xattr', '-d', 'com.apple.quarantine', driver_path, out: File::NULL, err: File::NULL)
        end

        # Apply to Selenium if setter exists
        if Selenium::WebDriver::Chrome.respond_to?(:driver_path=)
          Selenium::WebDriver::Chrome.driver_path = driver_path
        elsif defined?(Selenium::WebDriver::Chrome::Service) && Selenium::WebDriver::Chrome::Service.respond_to?(:driver_path=)
          Selenium::WebDriver::Chrome::Service.driver_path = driver_path
        end

        log "✅ Chromedriver ready at #{driver_path}"
        return
      else
        warn "⚠️ Chromedriver binary not found; Selenium Manager will attempt to download one automatically."
      end

      # No further action required — Selenium Manager will attempt to download
      # the driver automatically the first time a session is created.

    rescue => e
      warn "⚠️ Chromedriver setup error: #{e.class}: #{e.message}"
    end
  end
end
