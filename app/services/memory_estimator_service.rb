class MemoryEstimatorService
  # Constants for memory estimation
  AVERAGE_IMAGE_SIZE_MB = 2
  AVERAGE_VIDEO_SIZE_MB = 15
  MEMORY_OVERHEAD_MULTIPLIER = 1.5

  # Total memory budget for migrations
  TOTAL_MEMORY_MB = 60 * 1024  # 60GB
  MEMORY_BUFFER_MB = 4 * 1024  # 4GB buffer
  AVERAGE_MIGRATION_SIZE_MB = 4 * 1024  # 4GB per migration

  class << self
    # Estimate memory usage for a migration based on blobs
    #
    # @param blob_list [Array<Hash>] Array of blobs with sizes
    #   Each blob should have a :size_bytes key, or be identifiable by media type
    # @return [Integer] Estimated memory usage in MB
    def estimate(blob_list)
      return 0 if blob_list.blank?

      total_bytes = blob_list.sum do |blob|
        if blob[:size_bytes].present?
          blob[:size_bytes]
        else
          # Assume image size if no size provided
          AVERAGE_IMAGE_SIZE_MB * 1024 * 1024
        end
      end

      # Convert to MB and apply overhead multiplier
      total_mb = (total_bytes.to_f / (1024 * 1024)).ceil
      (total_mb * MEMORY_OVERHEAD_MULTIPLIER).to_i
    end

    # Calculate how many more concurrent migrations can be started
    #
    # @param current_memory_usage_mb [Integer] Current memory usage in MB
    # @return [Integer] Number of additional migrations that can be started
    def concurrent_migrations_allowed(current_memory_usage_mb)
      available_memory = TOTAL_MEMORY_MB - MEMORY_BUFFER_MB - current_memory_usage_mb

      # Calculate how many average migrations we can fit
      if available_memory > 0
        (available_memory.to_f / AVERAGE_MIGRATION_SIZE_MB).floor
      else
        0
      end
    end
  end
end
