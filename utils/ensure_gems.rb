# utils/ensure_gems.rb
# Ensures required gems for Selenium and Chromedriver are installed.
# Installs: selenium-webdriver, webdrivers
# Always runs (no skip logic)

REQUIRED_GEMS = %w[selenium-webdriver]

REQUIRED_GEMS.each do |gem_name|
  begin
    require gem_name
  rescue LoadError
    puts "🔧 Installing missing gem: #{gem_name}..."
    system("gem install #{gem_name}") || abort("❌ Failed to install #{gem_name}")
    require gem_name
  end
end
