# utils/browser_download.rb
#
# Fetches an asset through an existing, logged‑in Selenium driver
# (Basecamp or Google) and returns [Tempfile, mime] or nil.
#
require 'selenium-webdriver'
require 'tempfile'
require 'base64'

module Utils
  module BrowserDownload
    module_function

    # driver – a Selenium::WebDriver instance that is already on an
    #          authenticated page (Basecamp, Google, etc.).
    #
    def fetch(url, driver)
      return nil unless driver

      driver.execute_script("window.open('about:blank','asset_fetch');")
      drv = driver.switch_to.window('asset_fetch')
      drv.navigate.to(url)

      # wait up to 5 s for any network entry with this URL
      50.times do
        found = drv.execute_script(<<~JS, url)
          return performance.getEntriesByName(arguments[0]).length;
        JS
        break if found.to_i > 0
        sleep 0.1
      end

      # stream the bytes back as Base64
      base64 = drv.execute_async_script(<<~JS, url)
        const done = arguments[arguments.length - 1];
        fetch(arguments[0])
          .then(r => r.arrayBuffer())
          .then(buf => done(btoa(String.fromCharCode(...new Uint8Array(buf)))))
          .catch(() => done(null));
      JS

      driver.close
      driver.switch_to.window(driver.window_handles.first)

      return nil unless base64

      tmp = Tempfile.new(['browser_asset'])
      tmp.binmode
      tmp.write(Base64.decode64(base64))
      tmp.rewind
      [tmp, guess_mime(url)]
    rescue => e
      warn "⚠️  [BrowserDownload] #{e.class}: #{e.message}"
      nil
    end

    def guess_mime(url)
      case File.extname(url).downcase
      when '.png'          then 'image/png'
      when '.jpg', '.jpeg' then 'image/jpeg'
      when '.gif'          then 'image/gif'
      else                       'application/octet-stream'
      end
    end
  end
end
