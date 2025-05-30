# utils/retry_utils.rb
# frozen_string_literal: true

module Utils
  module RetryUtils
    extend self # Makes methods available as Utils::RetryUtils.method_name

    # Default jitter percentage (e.g., 0.2 for +/- 20%)
    # Can be overridden by an environment variable.
    DEFAULT_JITTER_PERCENTAGE = ENV.fetch('DEFAULT_JITTER_PERCENTAGE', 0.2).to_f

    # Calculates a sleep duration with random jitter.
    # Args:
    #   base_duration_seconds (Float): The base duration to sleep in seconds.
    #   jitter_percentage (Float): The percentage of jitter to apply (e.g., 0.2 for +/- 20%).
    # Returns:
    #   Float: The calculated sleep duration in seconds, guaranteed non-negative.
    def calculate_jittered_sleep(base_duration_seconds, jitter_percentage = DEFAULT_JITTER_PERCENTAGE)
      raise ArgumentError, "jitter_percentage must be between 0.0 and 1.0" unless jitter_percentage.between?(0.0, 1.0)
      raise ArgumentError, "base_duration_seconds must be non-negative" if base_duration_seconds < 0

      # Calculate jitter: (rand - 0.5) gives a range from -0.5 to 0.5.
      # Multiplying by 2 gives a range from -1.0 to 1.0.
      # So, jitter_amount will be between -base_duration * jitter_percentage and +base_duration * jitter_percentage.
      jitter_amount = base_duration_seconds * jitter_percentage * (rand - 0.5) * 2
      
      sleep_duration = base_duration_seconds + jitter_amount
      sleep_duration > 0 ? sleep_duration : 0 # Ensure sleep duration is not negative
    end

    # Performs a sleep with random jitter.
    # Args:
    #   base_duration_seconds (Float): The base duration to sleep in seconds.
    #   jitter_percentage (Float): The percentage of jitter to apply.
    def jitter_sleep(base_duration_seconds, jitter_percentage = DEFAULT_JITTER_PERCENTAGE)
      sleep_needed = calculate_jittered_sleep(base_duration_seconds, jitter_percentage)
      if sleep_needed > 0
        # Log the sleep for observability if needed, e.g., using Utils::Logging
        # log "[RetryUtils] Sleeping for %.2f seconds (base: %.2f, jitter: %.2f%%)" % [sleep_needed, base_duration_seconds, jitter_percentage*100]
        sleep(sleep_needed)
      end
    end

    # Example of how an exponential backoff with jitter might be structured
    # This is a conceptual example; actual implementation would integrate with HTTP clients.
    def exponential_backoff_with_jitter(max_retries: 5, 
                                          initial_delay_seconds: 0.5, 
                                          max_delay_seconds: 60.0, 
                                          multiplier: 2.0, 
                                          context: "operation")
      current_delay = initial_delay_seconds
      (1..max_retries).each do |attempt|
        # log "[RetryUtils] Attempt ##{attempt} for #{context} after delay of #{current_delay.round(2)}s"
        # yield # This would be the block of code to execute and retry
        # break if successful

        # Calculate next delay
        delay_with_jitter = calculate_jittered_sleep(current_delay)
        # log "[RetryUtils] #{context} failed on attempt ##{attempt}. Sleeping for #{delay_with_jitter.round(2)}s before next retry."
        sleep(delay_with_jitter)
        current_delay = [current_delay * multiplier, max_delay_seconds].min
        
        # raise "Max retries reached for #{context}" if attempt == max_retries
      end
    end

  end
end
