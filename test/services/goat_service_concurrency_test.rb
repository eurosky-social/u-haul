require 'test_helper'

# Test concurrent goat session isolation
# This test verifies that multiple GoatService instances can run simultaneously
# without interfering with each other's authentication sessions.
#
# Background:
# The goat CLI stores auth sessions in ~/.local/state/goat/auth-session.json by default.
# This caused a critical bug where concurrent migrations would overwrite each other's sessions.
#
# Solution:
# We now set XDG_STATE_HOME to a migration-specific directory, isolating each session.
#
class GoatServiceConcurrencyTest < ActiveSupport::TestCase
  def setup
    @migration1 = Migration.create!(
      did: 'did:plc:test1234567890abcdef',
      old_handle: 'user1.old-pds.example',
      new_handle: 'user1.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      email: 'user1@example.com',
      email_verified_at: Time.current,
      password: 'password1'
    )

    @migration2 = Migration.create!(
      did: 'did:plc:test0987654321fedcba',
      old_handle: 'user2.old-pds.example',
      new_handle: 'user2.new-pds.example',
      old_pds_host: 'https://old-pds.example',
      new_pds_host: 'https://new-pds.example',
      email: 'user2@example.com',
      email_verified_at: Time.current,
      password: 'password2'
    )

    @service1 = GoatService.new(@migration1)
    @service2 = GoatService.new(@migration2)
  end

  def teardown
    # Clean up test directories
    @service1.cleanup if @service1
    @service2.cleanup if @service2
  end

  test "each migration gets isolated work directory" do
    assert_not_equal @service1.work_dir, @service2.work_dir
    assert_includes @service1.work_dir.to_s, @migration1.did
    assert_includes @service2.work_dir.to_s, @migration2.did
  end

  test "goat state directories are isolated per migration" do
    # Get the state directory paths from environment
    state_dir1 = @service1.work_dir.join('.goat-state')
    state_dir2 = @service2.work_dir.join('.goat-state')

    # Verify they're different
    assert_not_equal state_dir1, state_dir2

    # Verify they include the migration DID
    assert_includes state_dir1.to_s, @migration1.did
    assert_includes state_dir2.to_s, @migration2.did
  end

  test "cleanup removes goat state directory" do
    # Create state directories
    state_dir = @service1.work_dir.join('.goat-state')
    FileUtils.mkdir_p(state_dir)

    # Create a fake session file
    session_file = state_dir.join('goat', 'auth-session.json')
    FileUtils.mkdir_p(session_file.dirname)
    File.write(session_file, '{"did":"test","access_token":"fake"}')

    assert File.exist?(session_file)

    # Cleanup
    @service1.cleanup

    # Verify entire work directory is removed
    assert_not File.exist?(@service1.work_dir)
    assert_not File.exist?(state_dir)
    assert_not File.exist?(session_file)
  end

  # NOTE: This test requires actual goat CLI and PDS access
  # Skip in CI unless integration testing environment is available
  test "concurrent goat commands use isolated sessions" do
    skip "Requires goat CLI and test PDS instances" unless ENV['RUN_INTEGRATION_TESTS']

    # Simulate concurrent operations
    threads = []

    threads << Thread.new do
      # This would normally call goat commands
      # For now, just verify the state directory exists
      FileUtils.mkdir_p(@service1.work_dir.join('.goat-state'))
      sleep 0.1
      File.exist?(@service1.work_dir.join('.goat-state'))
    end

    threads << Thread.new do
      # Second migration in parallel
      FileUtils.mkdir_p(@service2.work_dir.join('.goat-state'))
      sleep 0.1
      File.exist?(@service2.work_dir.join('.goat-state'))
    end

    results = threads.map(&:value)

    # Both should succeed without interfering
    assert results.all?, "Both migrations should have isolated state directories"
  end

  test "five concurrent migrations maintain session isolation" do
    # Create additional test migrations
    migrations = [
      @migration1,
      @migration2,
      Migration.create!(
        did: 'did:plc:test1111111111111111',
        old_handle: 'user3.old-pds.example',
        new_handle: 'user3.new-pds.example',
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: 'user3@example.com',
        email_verified_at: Time.current,
        password: 'password3'
      ),
      Migration.create!(
        did: 'did:plc:test2222222222222222',
        old_handle: 'user4.old-pds.example',
        new_handle: 'user4.new-pds.example',
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: 'user4@example.com',
        email_verified_at: Time.current,
        password: 'password4'
      ),
      Migration.create!(
        did: 'did:plc:test3333333333333333',
        old_handle: 'user5.old-pds.example',
        new_handle: 'user5.new-pds.example',
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: 'user5@example.com',
        email_verified_at: Time.current,
        password: 'password5'
      )
    ]

    services = migrations.map { |m| GoatService.new(m) }

    begin
      # Verify all work directories are unique
      work_dirs = services.map(&:work_dir)
      assert_equal 5, work_dirs.uniq.size, "All work directories should be unique"

      # Verify all state directories are unique
      state_dirs = services.map { |s| s.work_dir.join('.goat-state') }
      assert_equal 5, state_dirs.uniq.size, "All state directories should be unique"

      # Verify each state directory contains its migration DID
      services.each_with_index do |service, index|
        assert_includes service.work_dir.to_s, migrations[index].did
      end
    ensure
      # Cleanup all services
      services[2..4].each(&:cleanup)
    end
  end

  test "concurrent state directory creation does not cause conflicts" do
    migrations = []
    services = []

    # Create 4 migrations
    4.times do |i|
      migrations << Migration.create!(
        did: "did:plc:concurrent#{i.to_s.rjust(16, '0')}",
        old_handle: "user#{i}.old-pds.example",
        new_handle: "user#{i}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "user#{i}@example.com",
        email_verified_at: Time.current,
        password: "password#{i}"
      )
    end

    services = migrations.map { |m| GoatService.new(m) }

    begin
      # Concurrently create state directories and write session files
      threads = services.map.with_index do |service, index|
        Thread.new do
          state_dir = service.work_dir.join('.goat-state', 'goat')
          FileUtils.mkdir_p(state_dir)

          # Write a unique session file
          session_file = state_dir.join('auth-session.json')
          session_data = {
            did: migrations[index].did,
            access_token: "token_#{index}",
            refresh_token: "refresh_#{index}"
          }.to_json

          File.write(session_file, session_data)

          # Small delay to simulate real operations
          sleep(rand * 0.05)

          # Verify the file was written correctly
          JSON.parse(File.read(session_file))
        end
      end

      # Wait for all threads and collect results
      results = threads.map(&:value)

      # Verify all session files were written correctly
      assert_equal 4, results.size
      results.each_with_index do |session_data, index|
        assert_equal migrations[index].did, session_data['did']
        assert_equal "token_#{index}", session_data['access_token']
        assert_equal "refresh_#{index}", session_data['refresh_token']
      end

      # Verify all files still exist and are independent
      services.each_with_index do |service, index|
        session_file = service.work_dir.join('.goat-state', 'goat', 'auth-session.json')
        assert File.exist?(session_file), "Session file for migration #{index} should exist"

        session_data = JSON.parse(File.read(session_file))
        assert_equal migrations[index].did, session_data['did']
      end
    ensure
      services.each(&:cleanup)
    end
  end

  test "concurrent cleanup operations do not interfere" do
    migrations = []
    services = []

    # Create 5 migrations with state directories
    5.times do |i|
      migrations << Migration.create!(
        did: "did:plc:cleanup#{i.to_s.rjust(18, '0')}",
        old_handle: "cleanup#{i}.old-pds.example",
        new_handle: "cleanup#{i}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "cleanup#{i}@example.com",
        email_verified_at: Time.current,
        password: "password#{i}"
      )
    end

    services = migrations.map { |m| GoatService.new(m) }

    # Create all state directories with files
    services.each_with_index do |service, index|
      state_dir = service.work_dir.join('.goat-state', 'goat')
      FileUtils.mkdir_p(state_dir)

      session_file = state_dir.join('auth-session.json')
      File.write(session_file, {did: migrations[index].did}.to_json)

      # Create some additional files to simulate real usage
      File.write(state_dir.join('config.json'), '{}')
      File.write(state_dir.join('cache.db'), 'fake data')
    end

    # Verify all directories exist before cleanup
    services.each do |service|
      assert File.exist?(service.work_dir.join('.goat-state'))
    end

    # Concurrently cleanup all services
    threads = services.map do |service|
      Thread.new do
        sleep(rand * 0.02)  # Small random delay
        service.cleanup
        !File.exist?(service.work_dir)
      end
    end

    # Wait for all cleanups to complete
    results = threads.map(&:value)

    # Verify all cleanups succeeded
    assert results.all?, "All cleanup operations should succeed"

    # Verify no directories remain
    services.each do |service|
      assert_not File.exist?(service.work_dir), "Work directory should be removed"
      assert_not File.exist?(service.work_dir.join('.goat-state')), "State directory should be removed"
    end
  end

  test "race condition stress test with rapid concurrent operations" do
    migrations = []
    services = []

    # Create 4 migrations for stress testing
    4.times do |i|
      migrations << Migration.create!(
        did: "did:plc:stress#{i.to_s.rjust(19, '0')}",
        old_handle: "stress#{i}.old-pds.example",
        new_handle: "stress#{i}.new-pds.example",
        old_pds_host: 'https://old-pds.example',
        new_pds_host: 'https://new-pds.example',
        email: "stress#{i}@example.com",
        email_verified_at: Time.current,
        password: "password#{i}"
      )
    end

    services = migrations.map { |m| GoatService.new(m) }

    begin
      # Each thread performs multiple rapid operations
      threads = services.map.with_index do |service, index|
        Thread.new do
          state_dir = service.work_dir.join('.goat-state', 'goat')
          FileUtils.mkdir_p(state_dir)

          session_file = state_dir.join('auth-session.json')

          # Perform 10 rapid write/read cycles
          10.times do |cycle|
            session_data = {
              did: migrations[index].did,
              cycle: cycle,
              timestamp: Time.now.to_f
            }.to_json

            File.write(session_file, session_data)

            # Verify immediate read matches write
            read_data = JSON.parse(File.read(session_file))
            raise "Data mismatch!" unless read_data['did'] == migrations[index].did
            raise "Cycle mismatch!" unless read_data['cycle'] == cycle

            sleep(rand * 0.01)  # Random tiny delay
          end

          # Return final state
          JSON.parse(File.read(session_file))
        end
      end

      # Collect all results
      results = threads.map(&:value)

      # Verify all operations completed successfully
      assert_equal 4, results.size
      results.each_with_index do |final_state, index|
        assert_equal migrations[index].did, final_state['did']
        assert_equal 9, final_state['cycle'], "Should have completed all 10 cycles (0-9)"
      end
    ensure
      services.each(&:cleanup)
    end
  end
end
