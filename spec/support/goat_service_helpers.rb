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

  # GoatService authenticates over HTTP (minisky) rather than the goat CLI: the
  # old PDS from stored tokens, the new PDS from a password login. Stub both
  # session endpoints so examples exercise the method under test instead of
  # dying on an unstubbed login.
  def stub_pds_sessions(migration)
    [migration.old_pds_host, migration.new_pds_host].each do |host|
      %w[createSession refreshSession getSession].each do |endpoint|
        url = "#{host}/xrpc/com.atproto.server.#{endpoint}"
        body = pds_session_body(migration).to_json
        headers = { 'Content-Type' => 'application/json' }

        stub_request(:post, url).to_return(status: 200, body: body, headers: headers)
        stub_request(:get, url).to_return(status: 200, body: body, headers: headers)
      end
    end
  end

  def pds_session_body(migration)
    {
      accessJwt: fake_jwt,
      refreshJwt: fake_jwt(expires_at: 30.days.from_now),
      handle: migration.old_handle,
      did: migration.did,
      active: true
    }
  end

  # minisky parses the access token to decide whether to refresh: it wants three
  # dot-separated parts whose middle part base64-decodes to JSON with a numeric
  # exp, and raises "Invalid access token format" otherwise. Base64.decode64 is
  # what it uses, so encode with the standard alphabet rather than urlsafe.
  def fake_jwt(expires_at: 1.hour.from_now)
    header = Base64.strict_encode64({ alg: 'none', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ exp: expires_at.to_i }.to_json)
    "#{header}.#{payload}.signature"
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
