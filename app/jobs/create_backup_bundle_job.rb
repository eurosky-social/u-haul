# CreateBackupBundleJob - Creates downloadable backup bundle from downloaded data
#
# This job creates a ZIP archive containing the user's complete account data:
# - Repository (CAR file)
# - All blobs (images, videos, etc.)
# - Metadata file with migration info
#
# The bundle is created from already-downloaded data (DownloadAllDataJob) and:
# 1. Provides users with a backup before migration
# 2. Allows users to download their data
# 3. Stored for 24 hours then auto-deleted
#
# Flow:
# 1. Verify downloaded data exists
# 2. Create backup bundle directory
# 3. Create ZIP archive with all data
# 4. Create metadata file (JSON)
# 5. Update migration record with bundle path
# 6. Send email notification to user
# 7. Advance to backup_ready status
#
# Bundle Structure:
#   backup-{did}-{timestamp}.zip
#   ├── repo.car              (repository export)
#   ├── blobs/
#   │   ├── {cid1}
#   │   ├── {cid2}
#   │   └── ...
#   └── metadata.json         (migration info, DID, handles, timestamp)
#
# Storage:
#   tmp/bundles/{token}/backup.zip
#
# Cleanup:
#   Bundles are deleted after 24 hours by CleanupBackupBundleJob
#
# Error Handling:
# - Missing data: fail with error
# - ZIP creation failure: retry with backoff
# - Email failure: log warning but continue
# - Overall failure: mark migration as failed
#
# Usage:
#   CreateBackupBundleJob.perform_later(migration.id)

require 'zip'

class CreateBackupBundleJob < ApplicationJob
  queue_as :migrations

  # Retry configuration
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Creating backup bundle for migration #{migration.token} (DID: #{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_backup'
      logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping backup bundle creation")
      return
    end

    # Step 1: Verify downloaded data exists
    unless migration.downloaded_data_path.present? && Dir.exist?(migration.downloaded_data_path)
      raise "Downloaded data not found at: #{migration.downloaded_data_path}"
    end

    data_dir = Pathname.new(migration.downloaded_data_path)

    # Step 2: Create bundle directory
    bundle_dir = create_bundle_directory(migration)

    # Step 3: Create metadata file
    metadata_path = create_metadata_file(migration, data_dir, bundle_dir)

    # Step 4: Create ZIP archive
    bundle_path = create_zip_archive(migration, data_dir, bundle_dir, metadata_path)

    # Step 5: Update migration record
    migration.set_backup_bundle_path(bundle_path.to_s)

    # Step 6: Send email notification
    send_backup_ready_email(migration)

    logger.info("Backup bundle created: #{bundle_path} (#{format_bytes(File.size(bundle_path))})")

    # Step 7: Advance to next stage
    migration.advance_to_backup_ready!

  rescue StandardError => e
    logger.error("Backup bundle creation failed for migration #{migration&.id || migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    if migration
      migration.reload
      migration.mark_failed!("Backup bundle creation failed: #{e.message}")
    end

    raise
  end

  private

  # Create directory for bundle storage
  def create_bundle_directory(migration)
    bundle_dir = Rails.root.join('tmp', 'bundles', migration.token)

    # Clean up any existing bundle
    FileUtils.rm_rf(bundle_dir) if Dir.exist?(bundle_dir)

    # Create fresh directory
    FileUtils.mkdir_p(bundle_dir)

    bundle_dir
  end

  # Create metadata JSON file
  def create_metadata_file(migration, data_dir, bundle_dir)
    # Calculate statistics
    repo_size = File.exist?(data_dir.join('repo.car')) ? File.size(data_dir.join('repo.car')) : 0
    blobs_dir = data_dir.join('blobs')
    blob_count = Dir.exist?(blobs_dir) ? Dir.glob(blobs_dir.join('*')).length : 0
    total_blob_size = 0

    if Dir.exist?(blobs_dir)
      Dir.glob(blobs_dir.join('*')).each do |blob_file|
        total_blob_size += File.size(blob_file) if File.file?(blob_file)
      end
    end

    metadata = {
      migration_token: migration.token,
      did: migration.did,
      old_handle: migration.old_handle,
      new_handle: migration.new_handle,
      old_pds_host: migration.old_pds_host,
      new_pds_host: migration.new_pds_host,
      created_at: Time.current.iso8601,
      expires_at: 24.hours.from_now.iso8601,
      data: {
        repo_size_bytes: repo_size,
        blob_count: blob_count,
        total_blob_size_bytes: total_blob_size,
        total_size_bytes: repo_size + total_blob_size
      },
      instructions: "This backup contains your complete ATProto account data. " \
                    "Keep this file safe. It can be used to restore your account if needed. " \
                    "This backup will be available for download for 24 hours."
    }

    metadata_path = bundle_dir.join('metadata.json')
    File.write(metadata_path, JSON.pretty_generate(metadata))

    logger.info("Metadata created: repo=#{format_bytes(repo_size)}, " \
                "blobs=#{blob_count} (#{format_bytes(total_blob_size)})")

    metadata_path
  end

  # Create ZIP archive
  def create_zip_archive(migration, data_dir, bundle_dir, metadata_path)
    bundle_path = bundle_dir.join('backup.zip')

    logger.info("Creating ZIP archive: #{bundle_path}")

    Zip::File.open(bundle_path, create: true) do |zipfile|
      # Add metadata file
      zipfile.add('metadata.json', metadata_path)

      # Add repository CAR file
      repo_path = data_dir.join('repo.car')
      if File.exist?(repo_path)
        zipfile.add('repo.car', repo_path)
        logger.debug("Added repo.car (#{format_bytes(File.size(repo_path))})")
      end

      # Add all blobs
      blobs_dir = data_dir.join('blobs')
      if Dir.exist?(blobs_dir)
        blob_count = 0
        Dir.glob(blobs_dir.join('*')).each do |blob_file|
          next unless File.file?(blob_file)

          blob_name = File.basename(blob_file)
          zipfile.add("blobs/#{blob_name}", blob_file)
          blob_count += 1

          # Log progress every 100 blobs
          logger.debug("Added #{blob_count} blobs...") if (blob_count % 100).zero?
        end

        logger.info("Added #{blob_count} blobs to archive")
      end
    end

    bundle_path
  end

  # Send email notification
  def send_backup_ready_email(migration)
    MigrationMailer.backup_ready(migration).deliver_later
  rescue StandardError => e
    # Don't fail the job if email fails, just log it
    logger.warn("Failed to send backup ready email: #{e.message}")
  end

  # Format bytes for human-readable output
  def format_bytes(bytes)
    return "0 B" if bytes.zero?

    units = ['B', 'KB', 'MB', 'GB', 'TB']
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = [exp, units.length - 1].min

    value = bytes.to_f / (1024 ** exp)
    "#{value.round(2)} #{units[exp]}"
  end
end
