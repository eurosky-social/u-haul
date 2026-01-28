# Eurosky Migration - u-at-proto Integration

This document explains how to use the Eurosky Migration tool within the u-at-proto test environment.

## Overview

The Eurosky Migration tool is integrated as an **autonomous module** in the u-at-proto stack. It has its own:
- PostgreSQL database (`postgres-migration`)
- Redis instance (`redis-migration`)
- Rails web application (`migration-web`)
- Sidekiq worker (`migration-sidekiq`)

It can communicate with the PDS instances in the u-at-proto environment to perform test migrations.

## Quick Start

### 1. Start the entire u-at-proto stack (including migration tool)

```bash
cd /Users/svogelsang/Development/projects/Skeets/code/u-at-proto

# Start all services
docker compose up -d

# Check status
docker compose ps
```

The migration tool will be available at:
- **With Traefik**: https://migration.local.theeverythingapp.de
- **Direct access**: Run the standalone version separately (see below)

### 2. Start only the migration tool (without Traefik)

If you want to test the migration tool without the full u-at-proto stack:

```bash
cd /Users/svogelsang/Development/projects/Skeets/code/u-at-proto

# Start only migration services
docker compose up -d postgres-migration redis-migration migration-web migration-sidekiq

# Access at
# http://localhost:3000 (if not conflicting with other services)
```

### 3. Use the standalone version (recommended for development)

For development and testing, you can run the standalone version:

```bash
cd /Users/svogelsang/Development/projects/Skeets/code/u-at-proto/eurosky-migration

# Start standalone version
docker compose up -d

# Access at
# http://localhost:3000
# or http://sebastians-macbook-pro.tail8379bb.ts.net:3000
```

## Testing Migration Between PDS Instances

### Scenario: Migrate account from PDS to PDS2

1. **Create a test account on PDS (pds.local.theeverythingapp.de)**
   - Use the u-at-proto test scripts or manual account creation
   - Note the handle (e.g., `user.pds.local.theeverythingapp.de`)
   - Note the password

2. **Access the migration tool**
   - Open https://migration.local.theeverythingapp.de (if using Traefik)
   - Or http://localhost:3000 (if using standalone)

3. **Fill out the migration form**
   - **Email**: your-email@example.com
   - **Old Handle**: user.pds.local.theeverythingapp.de
   - **Password**: [your test account password]
   - **New PDS Host**: pds2.local.theeverythingapp.de
   - **New Handle**: user.pds2.local.theeverythingapp.de

4. **Monitor the migration**
   - The status page will auto-refresh every 10 seconds
   - Watch the progress through the 7 migration stages
   - When it reaches "pending_plc", you'll need to submit a PLC token

5. **Complete the PLC token step**
   - Check your email for the PLC token (if email is configured)
   - Or retrieve it from the logs: `docker compose logs migration-sidekiq`
   - Submit the token via the web form
   - Migration will complete automatically

## Architecture

### Services

```
eurosky-migration/
├── postgres-migration      # Autonomous PostgreSQL 15 instance
├── redis-migration         # Autonomous Redis 7 instance
├── migration-web           # Rails 7 web application
├── migration-sidekiq       # Background job processor
└── migration-https-check   # HTTPS health check (optional, Traefik only)
```

### Network Communication

- **Migration tool → PDS instances**: HTTP/HTTPS via Docker network
- **Migration tool → PLC directory**: https://plc.local.theeverythingapp.de
- **User → Migration tool**: HTTPS via Traefik or direct HTTP

### Data Isolation

Each component has its own volumes:
- `postgres_migration_data`: Migration database
- `redis_migration_data`: Redis cache/queue
- `migration_data`: Temporary migration files (/rails/tmp/goat)

## Environment Variables

Set in `/Users/svogelsang/Development/projects/Skeets/code/u-at-proto/.env`:

```bash
# Required
MIGRATION_MASTER_KEY=183aa0e598bd9bbd3e6f5718081b3db9

# Domain Configuration (inherited)
DOMAIN=theeverythingapp.de
PARTITION=local
```

The migration tool will use:
- Database: `postgresql://postgres:postgres@postgres-migration-local:5432/eurosky_migration_production`
- Redis: `redis://redis-migration-local:6379/0`
- PLC: `https://plc.local.theeverythingapp.de`
- Domain: `migration.local.theeverythingapp.de`

## Useful Commands

### View migration tool logs

```bash
# All migration services
docker compose logs -f migration-web migration-sidekiq

# Just web app
docker compose logs -f migration-web

# Just background jobs
docker compose logs -f migration-sidekiq
```

### Access Rails console

```bash
docker compose exec migration-web rails console
```

### Check migration database

```bash
docker compose exec postgres-migration psql -U postgres -d eurosky_migration_production

# List migrations
SELECT id, token, status, old_handle, new_handle, created_at FROM migrations;
```

### Reset migration database

```bash
docker compose exec migration-web rails db:reset
```

### Restart migration services

```bash
docker compose restart migration-web migration-sidekiq
```

## Troubleshooting

### Migration tool not accessible via Traefik

1. Check Traefik is running: `docker compose ps traefik`
2. Check Traefik logs: `docker compose logs traefik`
3. Verify DNS is configured: `https://migration.local.theeverythingapp.de` resolves
4. Check migration-web health: `docker compose ps migration-web`

### Handle resolution failing

The migration tool resolves handles to DIDs and PDS hosts automatically. If this fails:

1. Check PLC directory is running: `docker compose ps plc`
2. Test manual resolution:
   ```bash
   curl https://plc.local.theeverythingapp.de/did:plc:xxxxx
   ```
3. Check migration-web logs for resolution errors

### Database connection errors

1. Check postgres-migration is healthy: `docker compose ps postgres-migration`
2. Verify DATABASE_URL is correct in logs
3. Restart migration services: `docker compose restart migration-web migration-sidekiq`

### Sidekiq jobs not processing

1. Check Sidekiq is running: `docker compose ps migration-sidekiq`
2. View Sidekiq logs: `docker compose logs migration-sidekiq`
3. Check Redis connection: `docker compose exec migration-sidekiq redis-cli -h redis-migration-local ping`

## Development vs Production

### Development Mode (Standalone)

```bash
cd eurosky-migration
docker compose up -d
# Uses: RAILS_ENV=development, local ports, no SSL
```

### Production Mode (u-at-proto integrated)

```bash
cd u-at-proto
docker compose up -d
# Uses: RAILS_ENV=production, Traefik routing, SSL certificates
```

## Integration Points

The migration tool integrates with u-at-proto through:

1. **PLC Directory**: Resolves DIDs and updates PLC records
2. **PDS Instances**: Connects to source and target PDS for account migration
3. **Traefik**: HTTPS routing and SSL termination (optional)
4. **Docker Network**: Shared network for inter-service communication

## Next Steps

- Configure email notifications for migration status updates
- Set up monitoring and alerting for failed migrations
- Add admin interface for managing stuck migrations
- Write integration tests with u-at-proto test suite

## See Also

- [STATUS.md](STATUS.md) - Detailed project status
- [DOCKER.md](DOCKER.md) - Docker deployment guide
- [../README.md](../README.md) - u-at-proto main documentation
