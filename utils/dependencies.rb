# utils/dependencies.rb
#
# Light‑weight runtime dependency helper
# ──────────────────────────────────────
# • ensure_imagemagick – installs `identify` if missing (macOS or Debian/Ubuntu).
#   Returns true if the binary is available afterwards, false otherwise.

require 'rbconfig'

module Utils
  module Dependencies
    module_function

    def ensure_imagemagick
      return true if imagemagick_present?

      warn "⚠️  ImageMagick not found – attempting automatic install…"

      if mac?
        unless system('command -v brew > /dev/null')
          warn "❌ Homebrew not installed – cannot auto‑install ImageMagick."
          return false
        end
        system('brew', 'install', 'imagemagick')
      else # assume Debian/Ubuntu
        system('sudo', 'apt-get', 'update')
        system('sudo', 'apt-get', '-y', 'install', 'imagemagick')
      end

      imagemagick_present?
    end

    # ────────────────────────────────
    def imagemagick_present?
      system('which identify > /dev/null')
    end

    def mac?
      RbConfig::CONFIG['host_os'] =~ /darwin/i
    end
  end
end
