require "test_helper"

# Test that progress_data JSON serialization works with PostgreSQL's native jsonb column
class MigrationProgressDataTest < ActiveSupport::TestCase
  setup do
    @migration = Migration.new(
      did: "did:plc:progresstest#{SecureRandom.hex(4)}",
      email: "progress@test.com",
      old_pds_host: "https://old.example.com",
      old_handle: "user.old.com",
      new_handle: "user.new.com",
      new_pds_host: "https://new.example.com"
    )
    @migration.set_password("test123")
    @migration.save!
  end

  test "progress_data initializes as empty hash" do
    assert_equal({}, @migration.progress_data)
  end

  test "progress_data can store and retrieve nested hashes" do
    @migration.progress_data = {
      'blobs' => {
        'blob1' => { 'size' => 1024, 'uploaded' => 512 },
        'blob2' => { 'size' => 2048, 'uploaded' => 2048 }
      },
      'status' => 'uploading'
    }
    @migration.save!

    @migration.reload
    assert_equal 1024, @migration.progress_data['blobs']['blob1']['size']
    assert_equal 512, @migration.progress_data['blobs']['blob1']['uploaded']
    assert_equal 'uploading', @migration.progress_data['status']
  end

  test "progress_data can be modified in place" do
    @migration.progress_data['test_key'] = 'test_value'
    @migration.progress_data['nested'] = { 'key' => 'value' }
    @migration.save!

    @migration.reload
    assert_equal 'test_value', @migration.progress_data['test_key']
    assert_equal 'value', @migration.progress_data['nested']['key']
  end

  test "progress_data handles arrays" do
    @migration.progress_data = {
      'failed_blobs' => ['blob1', 'blob2', 'blob3'],
      'timestamps' => [Time.current.iso8601]
    }
    @migration.save!

    @migration.reload
    assert_equal 3, @migration.progress_data['failed_blobs'].length
    assert_equal 'blob1', @migration.progress_data['failed_blobs'][0]
    assert_instance_of Array, @migration.progress_data['failed_blobs']
  end

  test "progress_data handles numeric values" do
    @migration.progress_data = {
      'blobs_completed' => 42,
      'blobs_total' => 100,
      'bytes_transferred' => 1024000,
      'percentage' => 42.5
    }
    @migration.save!

    @migration.reload
    assert_equal 42, @migration.progress_data['blobs_completed']
    assert_equal 100, @migration.progress_data['blobs_total']
    assert_equal 1024000, @migration.progress_data['bytes_transferred']
    assert_equal 42.5, @migration.progress_data['percentage']
  end

  test "progress_data handles ISO8601 timestamp strings" do
    timestamp = Time.current.iso8601

    @migration.progress_data = {
      'blobs_started_at' => timestamp,
      'last_update' => Time.current.iso8601
    }
    @migration.save!

    @migration.reload
    assert_equal timestamp, @migration.progress_data['blobs_started_at']
    assert_match /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, @migration.progress_data['last_update']
  end

  test "progress_data can be updated via merge" do
    @migration.progress_data = { 'key1' => 'value1' }
    @migration.save!

    @migration.reload
    @migration.progress_data = @migration.progress_data.merge('key2' => 'value2')
    @migration.save!

    @migration.reload
    assert_equal 'value1', @migration.progress_data['key1']
    assert_equal 'value2', @migration.progress_data['key2']
  end

  test "progress_data preserves data types after reload" do
    @migration.progress_data = {
      'string' => 'text',
      'integer' => 123,
      'float' => 45.67,
      'boolean_true' => true,
      'boolean_false' => false,
      'null_value' => nil,
      'array' => [1, 2, 3],
      'hash' => { 'nested' => 'value' }
    }
    @migration.save!

    @migration.reload
    assert_equal 'text', @migration.progress_data['string']
    assert_equal 123, @migration.progress_data['integer']
    assert_equal 45.67, @migration.progress_data['float']
    assert_equal true, @migration.progress_data['boolean_true']
    assert_equal false, @migration.progress_data['boolean_false']
    assert_nil @migration.progress_data['null_value']
    assert_equal [1, 2, 3], @migration.progress_data['array']
    assert_equal({ 'nested' => 'value' }, @migration.progress_data['hash'])
  end

  test "database adapter is documented" do
    adapter = ActiveRecord::Base.connection.adapter_name

    # Document which adapter we're testing with
    puts "\n[progress_data test] Running with #{adapter} adapter"

    # All environments now use PostgreSQL with native jsonb column
    column = ActiveRecord::Base.connection.columns(:migrations).find { |c| c.name == 'progress_data' }
    assert_equal 'jsonb', column.sql_type, "Should use native jsonb column"
  end
end
