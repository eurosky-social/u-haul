#!/usr/bin/env bash
# # Quick test runner using rbenv exec to force Ruby 3.2.2

# cd "$(dirname "$0")"

# # Create storage directory
# mkdir -p storage

# # Use rbenv to run with Ruby 3.2.2
# echo "Running tests locally (SQLite) with Ruby 3.2.2..."
# rbenv exec -v 3.2.2 bundle exec rails test RAILS_ENV=test "$@"

docker compose exec eurosky-web bash -c 'RAILS_ENV=test DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@eurosky-postgres:5432/eurosky_migration_test" bundle exec rails test'
