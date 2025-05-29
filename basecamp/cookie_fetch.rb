# basecamp/cookie_fetch.rb
#
# Downloads any Basecamp blob using cookies from the logged‑in
# Selenium driver.  Works for both “download/IMG_xxx.jpg” and
# CloudFront signed URLs.
#
require 'open-uri'

module Basecamp
  module CookieFetch
    module_function

    def get(url, driver)
      return nil unless driver
      uri = URI(url)

      cookie_header = driver.manage.all_cookies
                            .select { |c| uri.host.end_with?(c[:domain].sub(/^\./, '')) }
                            .map { |c| "#{c[:name]}=#{c[:value]}" }
                            .join('; ')
      return nil if cookie_header.empty?

      URI.open(url, 'rb', 'Cookie' => cookie_header)
    rescue OpenURI::HTTPError
      nil
    end
  end
end
