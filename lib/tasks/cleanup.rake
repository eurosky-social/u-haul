namespace :migration do
  desc "Check for orphaned accounts on a PDS"
  task :check_orphaned, [:pds_host, :did] => :environment do |t, args|
    pds_host = args[:pds_host] || ENV['TARGET_PDS_HOST']
    did = args[:did]

    if pds_host.nil? || did.nil?
      puts "Usage: bundle exec rake migration:check_orphaned[PDS_HOST,DID]"
      puts "Example: bundle exec rake migration:check_orphaned[https://pds.example.com,did:plc:example123abc]"
      exit 1
    end

    puts "Checking for orphaned account on #{pds_host}"
    puts "DID: #{did}"
    puts ""

    # Check via API
    url = "#{pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{did}"
    response = `curl -s "#{url}"`
    parsed = JSON.parse(response) rescue {}

    if parsed['error'] == 'RepoDeactivated'
      puts "✓ Orphaned deactivated account found"
      puts "  Message: #{parsed['message']}"
      puts ""
      puts "To clean up this orphaned account:"
      puts "  1. SSH into the PDS server"
      puts "  2. Run: scripts/cleanup_orphaned_account_db.sh #{did}"
      puts "  OR use the PDS admin API to delete the account"
    elsif parsed['error'] == 'RepoNotFound'
      puts "✓ No account found - safe to create"
    elsif parsed['did']
      puts "⚠ Active account exists!"
      puts "  Handle: #{parsed['handle']}"
      puts "  This is NOT an orphaned account - migration should not proceed"
    else
      puts "? Unknown status"
      puts "  Response: #{response}"
    end
  end

  desc "List all failed migrations with AlreadyExists errors"
  task :list_orphaned_migrations => :environment do
    puts "Searching for failed migrations with AlreadyExists errors..."
    puts ""

    migrations = Migration.where(status: 'failed')
      .where("last_error LIKE ?", "%AlreadyExists%")
      .or(Migration.where(status: 'failed').where("last_error LIKE ?", "%Repo already exists%"))
      .order(created_at: :desc)

    if migrations.empty?
      puts "No failed migrations with AlreadyExists errors found."
      exit 0
    end

    puts "Found #{migrations.count} migrations:"
    puts ""

    migrations.each do |migration|
      puts "Token: #{migration.token}"
      puts "  DID: #{migration.did}"
      puts "  Old Handle: #{migration.old_handle}"
      puts "  New PDS: #{migration.new_pds_host}"
      puts "  Failed: #{migration.updated_at}"
      puts "  Error: #{migration.last_error&.truncate(100)}"
      puts ""
      puts "  To check: bundle exec rake migration:check_orphaned[#{migration.new_pds_host},#{migration.did}]"
      puts ""
    end
  end

  desc "Reset a failed migration to pending status for retry"
  task :reset_migration, [:token] => :environment do |t, args|
    token = args[:token]

    if token.nil?
      puts "Usage: bundle exec rake migration:reset_migration[TOKEN]"
      puts "Example: bundle exec rake migration:reset_migration[EURO-UGAGYPQP]"
      exit 1
    end

    migration = Migration.find_by(token: token)

    if migration.nil?
      puts "Migration not found: #{token}"
      exit 1
    end

    if migration.status != 'failed'
      puts "Migration is not in failed status (current: #{migration.status})"
      puts "Only failed migrations can be reset"
      exit 1
    end

    puts "Resetting migration #{migration.token}"
    puts "  DID: #{migration.did}"
    puts "  Current status: #{migration.status}"
    puts ""

    # Check if account still exists on target PDS
    url = "#{migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{migration.did}"
    response = `curl -s "#{url}"`
    parsed = JSON.parse(response) rescue {}

    if parsed['error'] == 'RepoDeactivated'
      puts "⚠ WARNING: Orphaned deactivated account still exists on target PDS"
      puts "  You must clean up the orphaned account before retrying"
      puts "  Run: scripts/cleanup_orphaned_account_db.sh #{migration.did}"
      puts ""
      print "Continue anyway? (yes/no): "
      answer = STDIN.gets.chomp
      if answer != 'yes'
        puts "Reset cancelled"
        exit 1
      end
    elsif parsed['error'] == 'RepoNotFound'
      puts "✓ Target PDS is clean - safe to retry"
    elsif parsed['did']
      puts "⚠ WARNING: Active account exists on target PDS with handle: #{parsed['handle']}"
      puts "  Cannot migrate to an already active account"
      exit 1
    end

    # Reset migration to pending status and schedule job
    migration.update!(
      status: 'pending_account',
      last_error: nil
    )

    # Manually schedule CreateAccountJob (schedule_first_job only runs on create)
    CreateAccountJob.perform_later(migration.id)

    puts ""
    puts "✓ Migration reset to pending_account status"
    puts "✓ CreateAccountJob scheduled"
    puts ""
    puts "Monitor progress:"
    puts "  docker compose logs -f sidekiq"
  end
end
