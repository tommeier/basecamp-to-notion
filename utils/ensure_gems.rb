# utils/ensure_gems.rb
# Ensures required gems for Selenium, Chromedriver and other runtime dependencies are installed.
# Installs: selenium-webdriver, mime-types (extend easily by editing REQUIRED_GEMS)
# Always runs (no skip logic)

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
    puts " Installing missing gem: #{gem_name}..."
    system("gem install #{gem_name}") || abort(" Failed to install #{gem_name}")
    
    # After installing, refresh Gem paths to ensure the new gem is in the load path
    Gem.clear_paths
    
    # For mini_magick specifically, ensure ImageMagick is available
    if gem_name == "mini_magick"
      puts " Checking for ImageMagick installation (required for mini_magick)..."
      unless system("which convert > /dev/null 2>&1") || system("which magick > /dev/null 2>&1")
        puts " ⚠️ Warning: ImageMagick does not appear to be installed."
        puts " mini_magick requires ImageMagick to work properly."
        puts " Please install ImageMagick (e.g., 'brew install imagemagick' on macOS)"
      end
    end
    
    # Try requiring again
    begin
      require require_path
    rescue LoadError => e
      puts " ⚠️ Warning: Installed #{gem_name} but still unable to load it: #{e.message}"
      puts " This may require a restart of Ruby or installation of additional dependencies."
      
      # For mini_magick, provide a fallback path
      if gem_name == "mini_magick"
        puts " Disabling image resizing functionality due to loading issues."
        # Set a global flag that can be checked to disable mini_magick features
        Object.const_set(:MINI_MAGICK_UNAVAILABLE, true)
      end
    end
  end
end
