# Docker Setup for Eurosky Migration

This document describes the Docker configuration for the Eurosky Migration Rails application.

## Overview

The application uses Docker Compose to orchestrate the following services:

- **caddy**: Caddy 2 reverse proxy with automatic HTTPS (ports 80/443)
- **postgres**: PostgreSQL 15 (Alpine) database
- **redis**: Redis 7 (Bookworm) for caching and background jobs (password-protected)
- **migrate**: One-time service that runs database migrations
- **web**: Rails web server (internal port 3000, proxied via Caddy)
- **sidekiq**: Background job processor for migrations

## Quick Start

1. Copy the environment template:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set required variables:
   - `POSTGRES_PASSWORD`: Secure database password
   - `REDIS_PASSWORD`: Secure Redis password
   - `SECRET_KEY_BASE`: Run `rails secret` to generate
   - `DOMAIN`: Your domain name (e.g., migration.example.com)
   - `EMAIL`: Your email for Let's Encrypt SSL certificates

3. Start all services:
   ```bash
   docker-compose up -d
   ```

4. Check service status:
   ```bash
   docker-compose ps
   ```

5. View logs:
   ```bash
   docker-compose logs -f caddy
   docker-compose logs -f web
   docker-compose logs -f sidekiq
   ```

6. Access the application:
   - Via domain: `https://{DOMAIN}` (e.g., https://migration.example.com)
   - For local testing without DNS: `http://localhost` (redirects to HTTPS)

## Service Details

### Caddy (Reverse Proxy)
- **Image**: caddy:2-alpine
- **Ports**: 80 (HTTP), 443 (HTTPS), 443/udp (HTTP/3)
- **Health Check**: HTTP GET to /health endpoint every 30s
- **Volumes**:
  - caddy-data (SSL certificates and Let's Encrypt data)
  - caddy-config (Caddy configuration cache)
- **Configuration**: Automatic HTTPS via Let's Encrypt
- **Features**:
  - Automatic SSL certificate generation and renewal
  - HTTP to HTTPS redirect
  - Reverse proxy to web service
  - Security headers (X-Frame-Options, X-Content-Type-Options, etc.)
  - Gzip and Zstandard compression
  - JSON logging to stdout

### PostgreSQL
- **Image**: postgres:15-alpine
- **Database**: eurosky_migration_production
- **Port**: 5432 (exposed for local development)
- **Health Check**: pg_isready every 10s
- **Volume**: postgres-data (persistent storage)
- **Network**: Internal Docker network only

### Redis
- **Image**: redis:7-bookworm
- **Port**: 6379 (internal only, not exposed to host)
- **Health Check**: redis-cli with password authentication every 10s
- **Volume**: redis-data (persistent storage)
- **Configuration**:
  - Append-only file enabled for durability
  - Password authentication required (via REDIS_PASSWORD env var)
  - Bound to internal Docker network only
  - No external exposure for security
- **Network**: Internal Docker network only

### Web Service
- **Build**: From Dockerfile (Ruby 3.2.2-alpine)
- **Command**: `bundle exec rails server -b 0.0.0.0 -p 3000`
- **Port**: 3000 (internal only, accessed via Caddy reverse proxy)
- **Health Check**: HTTP GET to /health endpoint every 30s
- **Dependencies**: Waits for postgres, redis, and migrations
- **Restart**: unless-stopped
- **Network**: Internal Docker network only
- **Access**: Only via Caddy reverse proxy at `https://{DOMAIN}`

### Sidekiq Service
- **Build**: From Dockerfile (Ruby 3.2.2-alpine)
- **Command**: `bundle exec sidekiq -C config/sidekiq.yml`
- **Health Check**: Process check every 30s
- **Dependencies**: Waits for postgres, redis, and migrations
- **Restart**: unless-stopped
- **Network**: Internal Docker network only

## Dockerfile Features

### Base Image
- Ruby 3.2.2-alpine for minimal footprint

### Multi-Stage Build
- **Build stage**: Installs build dependencies and gems
- **Final stage**: Only includes runtime dependencies

### Installed Tools
- PostgreSQL client
- goat CLI (v0.2.0) for ATProto migrations
- curl, wget, bash for scripting

### Security
- Non-root user (rails) for running the application
- Proper file permissions on sensitive directories

## Environment Variables

### Required
- `POSTGRES_PASSWORD`: Database password
- `REDIS_PASSWORD`: Redis password for authentication
- `SECRET_KEY_BASE`: Rails secret key (generate with `rails secret`)
- `DOMAIN`: Your domain name (e.g., migration.example.com)
- `EMAIL`: Email address for Let's Encrypt SSL certificates
- `RAILS_ENV`: Environment (default: production)
- `PORT`: Web server port (default: 3000, internal only)

### Optional
- `MAX_CONCURRENT_MIGRATIONS`: Number of concurrent migrations (default: 5)
- `SMTP_*`: Email configuration for notifications
- `SENTRY_DSN`: Error tracking
- `PLAUSIBLE_DOMAIN`: Analytics
- `REDIS_URL`: Custom Redis URL
- `DATABASE_URL`: Custom database URL

## Common Commands

### Start services
```bash
docker-compose up -d
```

### Stop services
```bash
docker-compose down
```

### Rebuild after code changes
```bash
docker-compose up -d --build
```

### View logs
```bash
docker-compose logs -f web
docker-compose logs -f sidekiq
```

### Run Rails console
```bash
docker-compose exec web bundle exec rails console
```

### Run database migrations
```bash
docker-compose exec web bundle exec rails db:migrate
```

### Access PostgreSQL
```bash
docker-compose exec postgres psql -U postgres -d eurosky_migration_production
```

### Access Redis CLI
```bash
# Authenticate with password
docker-compose exec redis redis-cli -a "${REDIS_PASSWORD}"

# Or use AUTH command after connecting
docker-compose exec redis redis-cli
AUTH ${REDIS_PASSWORD}
```

### Restart specific service
```bash
docker-compose restart web
docker-compose restart sidekiq
```

### Clean restart (remove volumes)
```bash
docker-compose down -v
docker-compose up -d
```

## Health Checks

All services include health checks for proper dependency management:

- **Caddy**: HTTP GET to /health endpoint (30s interval, 10s start period)
- **PostgreSQL**: `pg_isready` command (10s interval)
- **Redis**: `redis-cli ping` with password authentication (10s interval)
- **Web**: HTTP GET to /health endpoint (30s interval, 40s start period)
- **Sidekiq**: Process check via pgrep (30s interval)

## Volume Management

### Persistent Data
- `postgres-data`: PostgreSQL database files
- `redis-data`: Redis append-only file
- `caddy-data`: SSL certificates and Let's Encrypt account data
- `caddy-config`: Caddy configuration cache

### Development Mounts
- Application code is mounted to `/rails` in containers
- Excludes `/rails/tmp` to prevent host/container conflicts
- Caddyfile is mounted read-only to `/etc/caddy/Caddyfile`

## Troubleshooting

### Database connection issues
Check if postgres is healthy:
```bash
docker-compose ps postgres
docker-compose logs postgres
```

### Migration failures
View migrate service logs:
```bash
docker-compose logs migrate
```

### Sidekiq not processing jobs
Check Sidekiq logs and Redis connection:
```bash
docker-compose logs sidekiq
docker-compose exec redis redis-cli ping
```

### Port already in use (80 or 443)
If ports 80 or 443 are already in use by another service:
```bash
# Stop the conflicting service first, or
# Modify docker-compose.yml to use different ports for Caddy
```

### SSL Certificate Issues
If Let's Encrypt fails to generate certificates:
1. Ensure your domain's DNS points to the server's IP
2. Check that ports 80 and 443 are accessible from the internet
3. Verify EMAIL is set correctly in .env
4. Check Caddy logs: `docker-compose logs caddy`

For local development without a real domain, Caddy will use self-signed certificates.

## Production Deployment

For production deployment:

1. **DNS Configuration**: Point your domain to the server's IP address
2. **Environment Variables**: Set all required variables in `.env`
   - `DOMAIN`: Your production domain
   - `EMAIL`: Valid email for Let's Encrypt notifications
   - `POSTGRES_PASSWORD`: Strong, randomly generated password
   - `REDIS_PASSWORD`: Strong, randomly generated password
   - `SECRET_KEY_BASE`: Generate with `rails secret`
3. **Firewall Rules**: Ensure ports 80 and 443 are open for Caddy
4. **SSL Certificates**: Caddy automatically generates and renews Let's Encrypt certificates
5. **SMTP Settings**: Configure email for notifications
6. **Error Tracking**: Set up Sentry for error tracking
7. **Backup Strategies**: Configure proper backup strategies for volumes:
   - postgres-data
   - redis-data
   - caddy-data (SSL certificates)
8. **Monitoring**: Implement monitoring and logging (e.g., Prometheus, ELK)
9. **Security**: Redis is now secured with password authentication and bound to internal network only

## Caddy Reverse Proxy

Caddy acts as a reverse proxy in front of the Rails application, providing several benefits:

### Features
- **Automatic HTTPS**: Automatically obtains and renews Let's Encrypt SSL certificates
- **HTTP/3 Support**: Modern protocol support for improved performance
- **Security Headers**: Automatically adds security headers (X-Frame-Options, X-Content-Type-Options, etc.)
- **Compression**: Gzip and Zstandard compression for faster responses
- **Health Checks**: Proxies health check requests to the Rails application
- **Logging**: JSON-formatted logs sent to stdout

### Configuration
The Caddyfile is located at the root of the project and contains:
- Domain configuration from `DOMAIN` environment variable
- Email for Let's Encrypt from `EMAIL` environment variable
- Reverse proxy rules to forward traffic to `web:3000`
- Security headers and compression settings

### SSL Certificate Management
- Certificates are stored in the `caddy-data` volume
- Automatically renewed before expiration
- For local development without a valid domain, Caddy uses self-signed certificates
- For production, ensure your domain's DNS points to the server's IP address

### Accessing the Application
- **Production**: `https://{DOMAIN}` (e.g., https://migration.example.com)
- **Local Development**: `http://localhost` (will redirect to HTTPS with self-signed cert)

### Troubleshooting Caddy
```bash
# View Caddy logs
docker-compose logs -f caddy

# Check Caddy configuration
docker-compose exec caddy caddy validate --config /etc/caddy/Caddyfile

# Force certificate renewal (if needed)
docker-compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Redis Security

Redis is now secured with password authentication and network isolation:

### Security Features
- **Password Authentication**: All connections require password authentication via `REDIS_PASSWORD`
- **Internal Network Only**: Redis is not exposed to the host or internet, only accessible within Docker's internal network
- **Encrypted Connections**: All Redis connections use the password-protected URL format: `redis://:password@redis:6379/0`

### Connection Format
The Rails application and Sidekiq connect to Redis using:
```
redis://:${REDIS_PASSWORD}@redis:6379/0
```

The `initializers/redis.rb` file automatically handles password authentication:
- If `REDIS_URL` is set, it uses that value
- If `REDIS_PASSWORD` is set, it constructs the URL with password authentication
- Falls back to localhost:6379 for local development without password

### Best Practices
1. **Strong Passwords**: Use a strong, randomly generated password for `REDIS_PASSWORD`
2. **Environment Variables**: Never commit passwords to git, always use `.env` file
3. **Network Isolation**: Redis is only accessible within the Docker network, not from the host
4. **Regular Updates**: Keep Redis image up to date for security patches

### Connecting to Redis CLI
To connect to Redis from outside the container:
```bash
# Connect with password
docker-compose exec redis redis-cli -a "${REDIS_PASSWORD}"

# Test connection
docker-compose exec redis redis-cli -a "${REDIS_PASSWORD}" PING
```

## goat CLI Integration

The goat CLI is installed in the container and available at `/usr/local/bin/goat`. This tool is used for ATProto account migrations and can be invoked from within the Rails application or via docker exec:

```bash
docker-compose exec web goat --help
```

## Architecture

```
                    Internet
                        │
                        ▼
                ┌───────────────┐
                │     Caddy     │ :80, :443 (HTTPS)
                │ (Reverse Proxy│ + Let's Encrypt
                │  + SSL/TLS)   │
                └───────┬───────┘
                        │
                        ▼ internal network
                ┌───────────────┐
                │   Web         │ :3000 (internal)
                │ (Rails)       │
                └───────┬───────┘
                        │
         ┌──────────────┼──────────────┐
         │              │              │
         ▼              ▼              ▼
┌────────────┐  ┌─────────────┐  ┌─────────────┐
│ PostgreSQL │  │   Redis     │  │   Sidekiq   │
│  :5432     │  │   :6379     │  │ (Background)│
│            │  │ (password)  │  │             │
└────────────┘  └─────────────┘  └─────────────┘

All services communicate on internal Docker network.
Only Caddy is exposed to the internet on ports 80/443.
Redis requires password authentication.
```

## License

See LICENSE file in the root directory.
