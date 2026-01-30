# frozen_string_literal: true

module GoatServiceHelpers
  # Mock successful goat CLI execution
  def mock_goat_success(command_pattern, stdout: "", stderr: "", exit_status: 0)
    allow(Open3).to receive(:capture3).with(
      hash_including("GOAT_CONFIG" => anything),
      /#{Regexp.escape(command_pattern)}/,
      anything
    ).and_return([stdout, stderr, double(success?: exit_status == 0, exitstatus: exit_status)])
  end

  # Mock failed goat CLI execution
  def mock_goat_failure(command_pattern, error_message, exit_status: 1)
    allow(Open3).to receive(:capture3).with(
      hash_including("GOAT_CONFIG" => anything),
      /#{Regexp.escape(command_pattern)}/,
      anything
    ).and_return(["", error_message, double(success?: false, exitstatus: exit_status)])
  end

  # Mock HTTP requests via WebMock
  def mock_atproto_api(method, path, response_body: {}, status: 200, headers: {})
    default_headers = { 'Content-Type' => 'application/json' }.merge(headers)

    stub_request(method, /#{Regexp.escape(path)}/)
      .to_return(
        status: status,
        body: response_body.to_json,
        headers: default_headers
      )
  end

  # Create a test migration record
  def create_test_migration(attributes = {})
    default_attributes = {
      email: "test@example.com",
      did: "did:plc:test#{SecureRandom.hex(8)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: "pending_account"
    }

    Migration.create!(default_attributes.merge(attributes))
  end

  # Mock goat config file operations
  def mock_goat_config_file
    config_dir = Rails.root.join('tmp', 'test_goat_configs')
    FileUtils.mkdir_p(config_dir)
    allow_any_instance_of(GoatService).to receive(:config_path).and_return(
      config_dir.join("config_#{SecureRandom.hex(8)}.json")
    )
  end

  # Clean up test goat config files
  def cleanup_test_goat_configs
    config_dir = Rails.root.join('tmp', 'test_goat_configs')
    FileUtils.rm_rf(config_dir) if File.exist?(config_dir)
  end
end

RSpec.configure do |config|
  config.include GoatServiceHelpers

  config.after(:each) do
    cleanup_test_goat_configs
  end
end
