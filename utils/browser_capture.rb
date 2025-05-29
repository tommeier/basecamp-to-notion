# utils/browser_capture.rb
#
# Fetches a URL inside the logged-in Selenium driver and returns
# the raw bytes as a Tempfile plus its MIME type.
#
require 'selenium-webdriver'
require 'tempfile'
require 'base64'

module Utils
  module BrowserCapture
    module_function

    # url    – the asset URL to fetch
    # driver – a Selenium::WebDriver already logged in (BasecampSession or GoogleSession)
    # returns [Tempfile, mime] or nil on failure
    def fetch(url, driver)
      return nil unless driver

      # 1) open a blank tab and navigate there
      driver.execute_script("window.open('about:blank','asset_capture');")
      cap = driver.switch_to.window('asset_capture')
      cap.navigate.to(url)
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

      # 3) close the tab & switch back
      cap.close
      driver.switch_to.window(driver.window_handles.first)

      return nil unless data_url&.start_with?('data:')

      # 4) parse DataURL → Tempfile
      mime, b64 = data_url[/^data:(.*);base64,(.*)$/, 1..2]
      tmp = Tempfile.new(['browser_asset'])
      tmp.binmode
      tmp.write(Base64.decode64(b64))
      tmp.rewind

      [tmp, mime]
    rescue => e
      warn "⚠️  [BrowserCapture] #{e.class}: #{e.message}"
      nil
    end
  end
end
