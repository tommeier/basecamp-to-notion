# utils/ensure_gems.rb
# Ensures required gems for Selenium, Chromedriver and other runtime dependencies are installed.
# Installs: selenium-webdriver, mime-types (extend easily by editing REQUIRED_GEMS)
# Always runs (no skip logic)

require_relative './logging'

# Map of gem name -> library path to require.
# For gems where the require path matches the gem name, simply repeat it.
REQUIRED_GEMS = {
  "selenium-webdriver" => "selenium-webdriver",
  # Provides MIME::Types used for MIME type detection in uploads
  "mime-types"        => "mime-types",
  # Provides image resizing capabilities for handling large Google screenshots
  "mini_magick"       => "mini_magick"
}

REQUIRED_GEMS.each do |gem_name, require_path|
  begin
    require require_path
  rescue LoadError
    Utils::Logging.log "Installing missing gem: #{gem_name}..."
    system("gem install #{gem_name}") || abort(" Failed to install #{gem_name}")
    
    # After installing, refresh Gem paths to ensure the new gem is in the load path
    Gem.clear_paths
    
    # For mini_magick specifically, ensure ImageMagick is available
    if gem_name == "mini_magick"
      Utils::Logging.log "Checking for ImageMagick installation (required for mini_magick)..."
      unless system("which convert > /dev/null 2>&1") || system("which magick > /dev/null 2>&1")
        Utils::Logging.warn "ImageMagick does not appear to be installed."
        Utils::Logging.warn "mini_magick requires ImageMagick to work properly."
        Utils::Logging.warn "Please install ImageMagick (e.g., 'brew install imagemagick' on macOS)"
      end
    end
    
    # Try requiring again
    begin
      require require_path
    rescue LoadError => e
      Utils::Logging.warn "Installed #{gem_name} but still unable to load it: #{e.message}"
      Utils::Logging.warn "This may require a restart of Ruby or installation of additional dependencies."
      
      # For mini_magick, provide a fallback path
      if gem_name == "mini_magick"
        Utils::Logging.warn "Disabling image resizing functionality due to loading issues."
        # Set a global flag that can be checked to disable mini_magick features
        Object.const_set(:MINI_MAGICK_UNAVAILABLE, true)
      end
    end
  end
end
