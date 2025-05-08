# utils/ensure_gems.rb
# Ensures required gems for Selenium, Chromedriver and other runtime dependencies are installed.
# Installs: selenium-webdriver, mime-types (extend easily by editing REQUIRED_GEMS)
# Always runs (no skip logic)

# Map of gem name -> library path to require.
# For gems where the require path matches the gem name, simply repeat it.
REQUIRED_GEMS = {
  "selenium-webdriver" => "selenium-webdriver",
  # Provides MIME::Types used for MIME type detection in uploads
  "mime-types"        => "mime-types"
}

REQUIRED_GEMS.each do |gem_name, require_path|
  begin
    require require_path
  rescue LoadError
    puts " Installing missing gem: #{gem_name}..."
    system("gem install #{gem_name}") || abort(" Failed to install #{gem_name}")
    require require_path
  end
end
