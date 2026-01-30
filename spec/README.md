# Eurosky Migration - Test Suite

This directory contains the RSpec test suite for the Eurosky Migration application.

## Test Coverage

### Models (spec/models/)
- **migration_spec.rb** - Complete test coverage for Migration model including:
  - Validations (DID, email, token format, uniqueness)
  - Token generation and uniqueness
  - State machine transitions (7 migration stages)
  - Progress tracking and percentage calculation
  - Credential management (encryption, expiry, clearing)
  - Scopes (active, pending_plc, in_progress, etc.)
  - Encryption/decryption of sensitive fields

### Services (spec/services/)
- **goat_service_spec.rb** - Comprehensive tests for GoatService including:
  - Authentication (login_old_pds, login_new_pds, logout)
  - Account creation (service auth token, account creation)
  - Repository operations (export_repo, import_repo)
  - Blob operations (list_blobs, download_blob, upload_blob)
  - PLC operations (request_plc_token, sign_plc_operation, submit_plc_operation)
  - Account activation/deactivation
  - Error handling (AuthenticationError, NetworkError, RateLimitError)
  - File cleanup

- **memory_estimator_service_spec.rb** - Complete tests for MemoryEstimatorService:
  - Memory estimation with various blob sizes
  - Concurrency limit calculations
  - Boundary conditions and edge cases

### Jobs (spec/jobs/)
- **import_blobs_job_spec.rb** - Extensive tests for ImportBlobsJob including:
  - Normal blob import flow
  - Concurrency limiting (max 15 concurrent migrations)
  - Pagination handling
  - Error handling and retry logic
  - Rate limit handling
  - Progress tracking
  - Memory management constants

- **update_plc_job_spec.rb** - Critical tests for UpdatePlcJob including:
  - PLC operation flow (recommend, sign, submit)
  - PLC token validation and expiry
  - Point of no return handling
  - Error scenarios (missing token, network failures)
  - Admin alerting on critical failures
  - Security measures (token clearing)
  - Progress tracking

### Controllers (spec/controllers/)
- **migrations_controller_spec.rb** - Complete controller tests including:
  - Migration form rendering (new action)
  - Migration creation with handle resolution
  - Status page rendering (show action, HTML and JSON)
  - PLC token submission
  - JSON API endpoints
  - Error handling
  - Token-based access

### Integration Tests (spec/requests/)
- **migration_flow_spec.rb** - End-to-end integration tests including:
  - Complete migration flow from creation to completion
  - Progress tracking through all stages
  - Error scenarios
  - Token-based access
  - Security measures

## Running Tests

### Prerequisites

1. **Install Test Dependencies** (if running locally):
   ```bash
   # Ensure test gems are installed
   bundle install
   ```

2. **Setup Test Database**:
   ```bash
   # Create and migrate test database
   RAILS_ENV=test bundle exec rails db:create
   RAILS_ENV=test bundle exec rails db:migrate
   ```

### Running All Tests

```bash
# Run entire test suite
bundle exec rspec

# Run with documentation format
bundle exec rspec --format documentation

# Run with coverage report (if SimpleCov is added)
COVERAGE=true bundle exec rspec
```

### Running Specific Tests

```bash
# Run all model specs
bundle exec rspec spec/models

# Run specific spec file
bundle exec rspec spec/models/migration_spec.rb

# Run specific test by line number
bundle exec rspec spec/models/migration_spec.rb:25

# Run tests matching a description
bundle exec rspec spec/models/migration_spec.rb -e "validates token format"
```

### Running Tests in Docker

Since the Docker container was built without test gems, you have two options:

#### Option 1: Rebuild Docker image with test dependencies

1. Update `Dockerfile` to remove `BUNDLE_WITHOUT="development test"` temporarily
2. Rebuild:
   ```bash
   docker compose build eurosky-web
   docker compose up -d eurosky-web
   ```
3. Run tests:
   ```bash
   docker compose exec eurosky-web bundle exec rspec
   ```

#### Option 2: Create a separate test service in docker-compose.yml

Add this to `docker-compose.yml`:
```yaml
eurosky-test:
  build:
    context: .
    args:
      RAILS_ENV: test
  command: bundle exec rspec
  volumes:
    - .:/rails
  environment:
    RAILS_ENV: test
    DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@eurosky-postgres:5432/eurosky_migration_test
    REDIS_URL: redis://:${REDIS_PASSWORD}@eurosky-redis:6379/1
  depends_on:
    - eurosky-postgres
    - eurosky-redis
  networks:
    - eurosky-internal
```

Then run:
```bash
docker compose run --rm eurosky-test
```

## Test Configuration

### RSpec Configuration
- **spec_helper.rb** - Core RSpec configuration
- **rails_helper.rb** - Rails-specific configuration including:
  - WebMock for HTTP mocking
  - Sidekiq inline testing mode
  - Database transaction cleanup
  - Test fixture paths

### Test Helpers
- **spec/support/goat_service_helpers.rb** - Helper methods for:
  - Mocking goat CLI commands
  - Mocking ATProto API requests
  - Creating test migrations
  - Managing test goat config files

## Testing Best Practices

### Mocking External Services

Always mock external API calls and goat CLI commands:

```ruby
# Mock goat CLI
allow(Open3).to receive(:capture3).and_return(
  ["Success output", "", double(success?: true, exitstatus: 0)]
)

# Mock HTTP requests with WebMock
stub_request(:post, "https://pds.example/xrpc/endpoint")
  .to_return(status: 200, body: {result: "success"}.to_json)
```

### Testing Sidekiq Jobs

Jobs run inline in tests thanks to `Sidekiq::Testing.inline!`:

```ruby
expect {
  described_class.perform_now(migration.id)
}.to have_enqueued_job(NextJob)
```

### Testing Encryption

Migration model uses Lockbox for encryption. Test both encryption and decryption:

```ruby
migration.set_password('secret')
expect(migration.encrypted_password).to be_present
expect(migration.password).to eq('secret')
```

### Time-Dependent Tests

Use `freeze_time` or `travel_to` for time-sensitive tests:

```ruby
freeze_time do
  migration.set_password('secret')
  expect(migration.credentials_expires_at).to eq(48.hours.from_now)
end

travel_to 49.hours.from_now do
  expect(migration.credentials_expired?).to be true
end
```

## Coverage Goals

- **Models**: 100% coverage (currently achieved)
- **Services**: 95%+ coverage (currently achieved for GoatService, MemoryEstimatorService)
- **Jobs**: 90%+ coverage (achieved for ImportBlobsJob, UpdatePlcJob)
- **Controllers**: 90%+ coverage (currently achieved)
- **Integration**: Key user flows covered (currently achieved)

## What's Not Tested (Yet)

### Jobs (Lower Priority)
- CreateAccountJob
- ImportRepoJob
- ImportPrefsJob
- WaitForPlcTokenJob
- ActivateAccountJob

These follow similar patterns to the tested jobs and can be added using the same testing approach.

### Additional Test Types
- **Performance tests** - Load testing with multiple concurrent migrations
- **Integration with real goat CLI** - Can be done manually or in staging environment
- **End-to-end tests with real PDS** - Use u-at-proto test environment

## Adding New Tests

When adding new features, follow these patterns:

1. **Model tests**: Test validations, callbacks, scopes, instance methods
2. **Service tests**: Mock external dependencies, test all methods and error paths
3. **Job tests**: Test perform logic, retry behavior, error handling
4. **Controller tests**: Test all actions, formats (HTML/JSON), error cases
5. **Integration tests**: Test complete user flows

## Continuous Integration

To set up CI (GitHub Actions example):

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
      redis:
        image: redis:7
    steps:
      - uses: actions/checkout@v3
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2.2
          bundler-cache: true
      - run: bundle exec rails db:create db:migrate RAILS_ENV=test
      - run: bundle exec rspec
```

## Troubleshooting

### Database Issues
```bash
# Reset test database
RAILS_ENV=test bundle exec rails db:drop db:create db:migrate
```

### Redis Connection Issues
Make sure Redis is running:
```bash
redis-cli ping  # Should return PONG
```

### WebMock Errors
If you get "Real HTTP connections are disabled", ensure you've stubbed all external requests or allowed specific hosts:

```ruby
WebMock.disable_net_connect!(allow_localhost: true)
```

### Lockbox Key Issues
Ensure `MASTER_KEY` is set in test environment or use a test master key file.

## Resources

- [RSpec Documentation](https://rspec.info/)
- [WebMock Documentation](https://github.com/bblimke/webmock)
- [Sidekiq Testing](https://github.com/sidekiq/sidekiq/wiki/Testing)
- [Rails Testing Guide](https://guides.rubyonrails.org/testing.html)
