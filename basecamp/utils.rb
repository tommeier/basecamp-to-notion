# /basecamp/utils.rb

require_relative '../utils/logging'

module Basecamp
  module Utils
    extend ::Utils::Logging

    def self.with_retries(max_attempts = 5)
      attempt = 0

      begin
        if $shutdown
          log "🛑 Global shutdown flag detected before attempt ##{attempt + 1}. Exiting early."
          raise Interrupt, "Shutdown during with_retries"
        end

        yield
      rescue => e
        attempt += 1

        if $shutdown
          log "🛑 Shutdown flag detected during retry ##{attempt}. Exiting early."
          raise Interrupt, "Shutdown during with_retries"
        end

        if attempt < max_attempts
          sleep_time = 2 ** attempt
          error("🔁 Retry ##{attempt} in #{sleep_time}s due to: #{e.message}")

          sleep_time.times do
            sleep 1
            raise Interrupt, "Shutdown during retry sleep" if $shutdown
          end

          retry
        else
          raise e
        end
      end
    end
  end
end
