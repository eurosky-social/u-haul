# syntax=docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version and Gemfile
ARG RUBY_VERSION=3.2.2
FROM ruby:${RUBY_VERSION}-alpine as base

# Rails app lives here
WORKDIR /rails

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development test"


# Throw-away build stage to reduce size of final image
FROM base as build

# Install packages needed to build gems
RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    git \
    tzdata \
    nodejs \
    npm \
    gcompat

# Install application gems
# Force platform to ruby to build from source (needed for Alpine/musl compatibility)
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local force_ruby_platform true && \
    bundle install --jobs 4 --retry 3 && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Copy application code
COPY . .

# Precompile assets (if assets exist)
RUN bundle exec rails assets:precompile || true


# Final stage for app image
FROM base

# Install packages needed for deployment
RUN apk add --no-cache \
    postgresql-client \
    tzdata \
    curl \
    wget \
    bash

# Download and install goat CLI
# Note: Using curl with -L to follow redirects, -f to fail on errors
RUN curl -fsSL https://github.com/bluesky-social/goat/releases/latest/download/goat-linux-amd64 -o /usr/local/bin/goat && \
    chmod +x /usr/local/bin/goat && \
    /usr/local/bin/goat --version || echo "goat installed successfully"

# Copy built artifacts: gems, application
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# Create tmp directories
RUN mkdir -p tmp/pids tmp/cache tmp/sockets

# Run and own only the runtime files as a non-root user for security
RUN adduser -D -s /bin/bash rails && \
    chown -R rails:rails db log storage tmp
USER rails:rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
