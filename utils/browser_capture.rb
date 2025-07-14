# utils/browser_capture.rb
#
# Fetches a URL inside the logged-in Selenium driver and returns
# the raw bytes as a Tempfile plus its MIME type.
#
require 'selenium-webdriver'
require 'tempfile'
require 'base64'
require_relative 'logging'

module Utils
  module BrowserCapture
    extend Utils::Logging
    module_function

    # url    – the asset URL to fetch
    # driver – a Selenium::WebDriver already logged in (BasecampSession or GoogleSession)
    # context – optional string used for logging/debugging
    # returns [Tempfile, mime] or nil on failure
    def fetch(url, driver, context: nil)
      return nil unless driver

      debug "🔍 [BrowserCapture] Fetching via browser: #{url} (#{context})" if context

      # 1) open a blank tab named 'asset_capture' and navigate there safely
      original_window = driver.window_handle
      driver.execute_script("window.open('about:blank','asset_capture');")
      # Wait briefly for the new window to register
      Selenium::WebDriver::Wait.new(timeout: 5).until { (driver.window_handles - [original_window]).any? }

      # Switch to the new window (returns the driver itself in recent Selenium versions)
      driver.switch_to.window('asset_capture')
      driver.navigate.to(url)
      sleep 0.5  # allow resources to load

      # 2) fetch inside the page as a Blob → DataURL
      data_url = driver.execute_async_script(<<~JS, url)
        const done = arguments[arguments.length - 1];
        fetch(arguments[0])
          .then(r => r.blob())
          .then(blob => {
            const reader = new FileReader();
            reader.onload = () => done(reader.result);
            reader.onerror = () => done(null);
            reader.readAsDataURL(blob);
          })
          .catch(() => done(null));
      JS

      # 3) close the tab & switch back to the original window
      driver.close
      driver.switch_to.window(original_window)

      return nil unless data_url&.start_with?('data:')

      # 4) parse DataURL → Tempfile safely
      md = data_url.match(/\Adata:(.+?);base64,(.+)\z/m)
      unless md && md[1] && md[2]
        warn "⚠️  [BrowserCapture] Unable to parse DataURL for #{url} (#{context})"
        return nil
      end

      mime = md[1]
      b64  = md[2]

      tmp = Tempfile.new(['browser_asset'])
      tmp.binmode
      tmp.write(Base64.decode64(b64))
      tmp.rewind

      debug "✅ [BrowserCapture] Fetched #{url} (#{mime || 'unknown mime'}) – #{tmp.size} bytes (#{context})" if context
      [tmp, mime]
    rescue => e
      warn "⚠️  [BrowserCapture] #{e.class}: #{e.message} (#{context})"
      nil
    end
  end
end
