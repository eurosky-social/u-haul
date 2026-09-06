# eu-haul 🚚

> Self-hosted ATProto account migration tool for Bluesky and the AT Protocol ecosystem

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ruby 3.2.2](https://img.shields.io/badge/ruby-3.2.2-ruby.svg)](https://www.ruby-lang.org/)
[![Rails 7.1.3](https://img.shields.io/badge/rails-7.1.3-red.svg)](https://rubyonrails.org/)

**eu-haul** is a standalone web application that helps you migrate your Bluesky/ATProto account from one Personal Data Server (PDS) to another. It provides a simple web interface to handle the entire migration process, including repository export/import, blob transfer, preferences migration, and PLC directory updates.

## Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Legal Pages](#legal-pages)
- [Migration Process](#migration-process)
- [Deployment](#deployment)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Features

- **Web-Based Interface**: Simple form-based migration process, no command-line required
- **Complete Migration**: Transfers repository data, blobs (images/videos), and preferences
- **Backup Bundle** (Optional): Download a complete ZIP archive of your account before migration
- **Rotation Keys**: Receive account recovery keys for reverting PLC changes if needed
- **Progress Tracking**: Real-time status updates with percentage completion
- **Secure**: Encrypted credential storage with automatic expiration and cleanup
- **Memory-Optimized**: Sequential blob processing prevents memory exhaustion
- **Token-Based Access**: No authentication required, shareable migration status URLs
- **Background Processing**: Sidekiq-powered async jobs for reliability
- **Error Recovery**: Automatic retry logic with detailed error reporting
- **Self-Hosted**: Run on your own infrastructure, maintain full control

## How It Works

u-haul provides a web interface for ATProto account migrations, communicating directly with the AT Protocol APIs. The migration happens in **7 sequential stages**:

1. **Create Account** - Creates a deactivated account on the target PDS
2. **Import Repository** - Exports and imports your repository (posts, follows, blocks, etc.)
3. **Transfer Blobs** - Copies all media files (images, videos, avatars)
4. **Import Preferences** - Transfers your Bluesky app preferences
5. **Request PLC Token** - Sends a token to your email for identity verification
6. **Update PLC Directory** - Updates the global directory to point to your new PDS ⚠️ **Point of no return**
7. **Activate Account** - Activates the new account and deactivates the old one

## Prerequisites

- **Docker** and **Docker Compose** (recommended) OR
- **Ruby 3.2.2**, **PostgreSQL 15**, **Redis 7** (for local development)
- Access to both source and target PDS instances
- Admin credentials or invite code for target PDS (if required)

## Quick Start

### Using Docker (Recommended)

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/u-haul.git
   cd u-haul
   ```

2. **Set up environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env and set your configuration
   ```

3. **Generate encryption keys:**
   ```bash
   # Master key for Lockbox encryption (32 bytes = 64 hex characters)
   openssl rand -hex 32

   # Active Record encryption keys (run 3 times)
   openssl rand -hex 32
   openssl rand -hex 32
   openssl rand -hex 32
   ```

   Add these to your `.env` file:
   ```bash
   MIGRATION_MASTER_KEY=<your-hex-32-key>
   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=<your-hex-32-key-1>
   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=<your-hex-32-key-2>
   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=<your-hex-32-key-3>
   ```

4. **Start the application:**
   ```bash
   docker compose up -d
   ```

   `docker-compose.yml` is self-contained. If you also run a local
   [u-at-proto](https://github.com/eurosky-social/u-at-proto) stack and want the
   app to reach its PDS containers, add the override file:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.u-at-proto.yml up -d
   ```

5. **Access the web interface:**
   - Open http://localhost:3001 (port 3001 on the host, 3000 inside the container)
   - Fill out the migration form
   - Monitor your migration progress

### Local Development Setup

See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for detailed local setup instructions.

## Configuration

All configuration is done via environment variables in the `.env` file. See [`.env.example`](.env.example) for a complete reference.

### Essential Configuration

```bash
# Database
POSTGRES_PASSWORD=your-secure-password

# Redis
REDIS_PASSWORD=your-secure-redis-password

# Rails
SECRET_KEY_BASE=generate-with-rails-secret
RAILS_ENV=production

# Encryption (CRITICAL - generate unique keys)
MIGRATION_MASTER_KEY=your-hex-32-key
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=your-hex-32-key
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=your-hex-32-key
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=your-hex-32-key

# Domain (for production)
DOMAIN=migration.yourdomain.com
EMAIL=admin@yourdomain.com
```

### Optional Configuration

```bash
# Migration Settings
MAX_CONCURRENT_MIGRATIONS=100  # Anti-abuse limit on total active migrations

# SMTP (for email notifications)
SMTP_ADDRESS=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=noreply@yourdomain.com
SMTP_PASSWORD=your-smtp-password

# Legacy Blob Support
CONVERT_LEGACY_BLOBS=false  # Enable if migrating pre-2023 accounts

# Deployment Mode
DEPLOYMENT_MODE=standalone  # or "bound" to lock to specific PDS
TARGET_PDS_HOST=https://your-pds.example.com  # Required if mode=bound

# Invite Code
INVITE_CODE_MODE=optional  # "required", "optional", or "hidden"

# UI Customization
SITE_NAME=Account Migration
PRIMARY_COLOR=#667eea
SECONDARY_COLOR=#764ba2

# Legal Pages (optional)
# If set, links to these URLs are shown in the wizard footer
PRIVACY_POLICY_URL=https://yourdomain.com/privacy-policy.html
TERMS_OF_SERVICE_URL=https://yourdomain.com/terms-of-service.html
```

### Legal Pages

Example Privacy Policy and Terms of Service templates are included in the project root:

```
privacy-policy.html    # Example privacy policy template
terms-of-service.html  # Example terms of service template
```

These are **not active by default** — they live outside `public/` so they won't be served until you explicitly move them. To use them:

1. **Fill in the placeholders** — open each file and replace:
   - `[Your Name / Organization]` — your legal entity or operator name
   - `[your-email]` — your support/contact email
   - `[Date]` — the effective date
   - `[Your Jurisdiction / Country]` — governing law jurisdiction (ToS only)
   - `[X] days` — how long server logs are retained (Privacy Policy only)
   - `[€100 / ...]` — liability cap or remove the clause (ToS only)

2. **Move them to `public/`** so Rails serves them as static files:
   ```bash
   mv privacy-policy.html public/
   mv terms-of-service.html public/
   ```

3. **Set the env vars** in `.env`:
   ```bash
   PRIVACY_POLICY_URL=https://yourdomain.com/privacy-policy.html
   TERMS_OF_SERVICE_URL=https://yourdomain.com/terms-of-service.html
   ```

4. Links will appear in the migration wizard footer automatically.

Alternatively, skip steps 1–2 entirely and point the env vars at any external URL (e.g. a hosted legal page on your main website).

> **Note:** The example documents are templates only — they do not constitute legal advice. Review them with a qualified professional before deploying to users.

## Migration Process

### Starting a Migration

1. **Navigate to the web interface** at http://localhost:3000
2. **Fill out the migration form:**
   - Your email address (for notifications and PLC token)
   - Old account handle (e.g., `alice.bsky.social`)
   - Old account password (used to obtain access/refresh tokens, not stored)
   - New PDS host (e.g., `https://pds.example.com`)
   - New handle (e.g., `alice.pds.example.com`)
   - Invite code (if required by target PDS)
   - **Create backup bundle** (optional, recommended): Downloads a complete ZIP backup of your account

3. **Submit the form** - You'll receive a unique migration token (e.g., `EURO-ABC12345`)

**Backup Bundle Option:**
If you enabled backup creation, the migration will:
- Download all your data (posts, media, profile) to a ZIP file
- Send you an email when the backup is ready (available for 24 hours)
- Allow you to download the backup before migration proceeds
- Automatically continue migration after backup is created

This provides a safety net - you'll have a complete local copy of your account.

### Monitoring Progress

- The status page auto-refreshes every 10 seconds
- View real-time progress with percentage completion
- During blob transfer, see:
  - Number of blobs uploaded / total
  - Data transferred (MB/GB)
  - Estimated time remaining

### Completing the Migration

When the migration reaches **"Waiting for PLC Token"**:

1. Check your email for the PLC token
2. Enter the token on the status page
3. **Save your rotation key** - displayed on the status page (copy and store securely)
4. ⚠️ **This is the point of no return** - your DID will be updated to point to the new PDS
5. The migration will automatically complete by activating the new account

**About Rotation Keys:**
The rotation key is an account recovery mechanism. It allows you to revert your DID back to the old PDS if something goes wrong. Store it securely - you won't be able to retrieve it later. See [Backup and Rotation Keys Documentation](docs/BACKUP_AND_ROTATION_KEYS.md) for details.

### Migration URLs

Bookmark your migration status URL:
```
http://localhost:3000/migrate/EURO-ABC12345
```

Share this URL to check progress from any device (token is unguessable for security).

## Deployment

### Docker Compose (Production)

1. **Set production environment:**
   ```bash
   RAILS_ENV=production
   FORCE_SSL=true
   DOMAIN=migration.yourdomain.com
   ```

2. **Set up reverse proxy:**
   - Use Caddy, Nginx, or Traefik for SSL termination
   - Example Caddy configuration included in [`compose.yml.production`](compose.yml.production)

3. **Start services:**
   ```bash
   docker compose -f compose.yml.production up -d
   ```

4. **Health check:**
   ```bash
   curl https://migration.yourdomain.com/up
   ```

### Memory Requirements

- **Minimum**: 4GB RAM
- **Recommended**: 8GB RAM
- **Optimal**: 16GB+ RAM

All migrations run in parallel with no global limit. Each migration uses 5 threads for blob transfers, and blobs are streamed to/from disk so memory usage is constant (~16KB per thread) regardless of blob size. `MAX_CONCURRENT_MIGRATIONS` is an anti-abuse gate that limits how many migrations can be active simultaneously (default: 100).

### Monitoring

- **Health endpoint**: `GET /up` (returns 200 OK if healthy)
- **Sidekiq logs**: `docker compose logs -f sidekiq`
- **Application logs**: `docker compose logs -f web`
- **Rails console**: `docker compose exec web rails console`

### Safe Restarts

Restarting containers while migrations are running requires care. The `UpdatePlcJob` modifies the PLC directory (an irreversible operation) and **must not be interrupted mid-execution**. Use the provided script to gracefully drain Sidekiq workers before restarting:

```bash
# Restart all services (drains Sidekiq first)
./scripts/safe-restart.sh

# Restart only the web server (safe anytime, no drain needed)
./scripts/safe-restart.sh web

# Restart only the critical Sidekiq worker (graceful drain)
./scripts/safe-restart.sh critical

# Restart both Sidekiq workers
./scripts/safe-restart.sh sidekiq

# Custom drain timeout (default: 60s) and skip confirmation
./scripts/safe-restart.sh -t 120 -y all
```

The script:
1. Sends `TSTP` to Sidekiq (stops fetching new jobs, keeps processing current ones)
2. Waits for in-flight jobs to finish (with configurable timeout)
3. Stops and restarts the containers

If you need to restart manually without the script:
```bash
# Step 1: Quiet Sidekiq (stop fetching new jobs)
docker compose kill -s TSTP eurosky-sidekiq-critical

# Step 2: Watch logs until idle
docker compose logs -f eurosky-sidekiq-critical

# Step 3: Stop and restart
docker compose stop eurosky-sidekiq-critical
docker compose start eurosky-sidekiq-critical
```

**Important**: Never force-kill (`docker compose kill`) the `eurosky-sidekiq-critical` container while `UpdatePlcJob` is running. If the job is interrupted after submitting the PLC operation but before updating the migration status, the migration will be left in an inconsistent state requiring manual recovery.

### Scheduled Jobs (Security)

The application automatically runs scheduled cleanup jobs via Sidekiq:

- **Credential Cleanup**: Every 6 hours - purges expired access/refresh tokens and PLC tokens
- **Backup Cleanup**: Every hour - removes expired backup bundles to free disk space

These jobs run automatically when Sidekiq starts. No external cron configuration is needed. You can view the schedule in [config/sidekiq.yml](config/sidekiq.yml).

To manually trigger cleanup:
```bash
# Cleanup expired credentials
docker compose exec web rails runner "CleanupExpiredCredentialsJob.perform_now"

# Cleanup expired backups
docker compose exec web rails runner "CleanupBackupBundleJob.perform_now"
```

## Architecture

### Tech Stack

- **Backend**: Rails 7.1.3 (API + views)
- **Database**: PostgreSQL 15
- **Cache/Queue**: Redis 7
- **Background Jobs**: Sidekiq 7.2
- **Encryption**: Lockbox (AES-256-GCM)
- **ATProto**: Direct AT Protocol API integration

### Migration Flow

```
User Form → CreateAccountJob → ImportRepoJob → ImportBlobsJob → ImportPrefsJob
                                                                      ↓
                                                            WaitForPlcTokenJob
                                                                      ↓
                                                    User submits PLC token
                                                                      ↓
                                                              UpdatePlcJob ⚠️
                                                                      ↓
                                                           ActivateAccountJob
                                                                      ↓
                                                                  COMPLETED ✅
```

### Security

- **Credential Encryption**: Access/refresh tokens encrypted with Lockbox (AES-256-GCM)
- **Auto-Expiration**: Access/refresh tokens deleted immediately on completion, PLC tokens expire after 1h
- **Automatic Cleanup**: Credentials are cleared immediately after successful migration
- **Background Purging**: Expired credentials are automatically purged every 6 hours
- **Token-Based Access**: Unguessable tokens (62^16 = ~47 bits entropy)
- **Rate Limiting**: Production deployments enforce strict rate limits via Caddy (see [RATE_LIMITING.md](RATE_LIMITING.md))
  - Migration creation: 5 per IP per hour
  - PLC token submission: 10 per IP per hour
  - Status page views: 100 per IP per hour
- **No Plain-Text Storage**: All sensitive data encrypted at rest
- **Data Minimization**: Credentials are deleted as soon as they're no longer needed (GDPR compliant)

### File Structure

```
u-haul/
├── app/
│   ├── controllers/     # MigrationsController (form, status, token submission)
│   ├── jobs/            # 7 Sidekiq jobs (migration stages)
│   ├── models/          # Migration model (state machine, encryption)
│   ├── services/        # ATProto API client + migration orchestration
│   └── views/           # Web interface (form, status page)
├── config/              # Rails configuration
├── db/                  # Database migrations
├── docker-compose.yml   # Development stack
├── compose.yml.production  # Production stack with Caddy
├── Dockerfile           # Multi-stage build
├── scripts/             # Admin scripts (cleanup orphaned accounts)
└── docs/                # Additional documentation
```

## Troubleshooting

### Common Issues

#### "AlreadyExists: Repo already exists"

This means a previous migration failed after creating the account on the target PDS. The account exists but is deactivated.

**Solution**: Clean up the orphaned account using the provided scripts:

```bash
cd scripts
./cleanup_orphaned_account_db.sh did:plc:your-did-here
```

See [`scripts/README.md`](scripts/README.md) for detailed cleanup instructions.

Since September 2026 eu-haul recognises a deactivated account that the **same** migration created on an earlier run and simply continues, so this cleanup is only needed for accounts left behind by a different, older migration.

#### "A request body was provided when none was expected" at the PLC token step

The old PDS rejected the PLC token request (`com.atproto.identity.requestPlcOperationSignature`) because the request arrived with body framing. This happens when the old PDS sits behind a proxy that re-frames bodyless POSTs as `Transfer-Encoding: chunked` — most commonly a Cloudflare Tunnel (see [bluesky-social/atproto#3267](https://github.com/bluesky-social/atproto/issues/3267)). eu-haul sends these calls without a body and retries the transient rejection a few times, but a tunnel can still produce it.

**Solution** (operator of the old PDS): disable chunked encoding on the tunnel origin — `noChunkedEncoding: true` in the origin request settings of `cloudflared`, or "Disable chunked encoding" in the Zero Trust dashboard — then request a new PLC token from the migration page.

#### Migration stuck at "pending_blobs"

Check Sidekiq logs for errors:
```bash
docker compose logs -f sidekiq
```

Common causes:
- Network issues between PDS instances
- Blob not found on source PDS
- Target PDS storage full

#### "RepoDeactivated" error

The account on the target PDS is deactivated. This is expected during migration. If it persists after completion, check the ActivateAccountJob logs.

#### Database connection errors

Restart the services:
```bash
docker compose restart web sidekiq
```

If the issue persists, check PostgreSQL logs:
```bash
docker compose logs postgres
```

### Getting Help

- **Check logs**: `docker compose logs -f web sidekiq`
- **Rails console**: `docker compose exec web rails console` to inspect migration state
- **GitHub Issues**: Report bugs or request features

## Additional Documentation

- **[Backup and Rotation Keys](docs/BACKUP_AND_ROTATION_KEYS.md)** - Detailed guide on backup bundles and account recovery keys
- **[DOCKER.md](DOCKER.md)** - Docker deployment guide
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Development and contribution guidelines

## Development

### Running Tests

```bash
docker compose exec web rails test
```

### Adding New Features

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

### Project Structure

- **Models**: State machine logic, validations, encryption
- **Services**: External API calls, CLI wrapper
- **Jobs**: Async migration stages with retry logic
- **Controllers**: Thin controllers, delegate to jobs

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Code of Conduct
- Development setup
- Pull request process
- Testing requirements
- Code style guidelines

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Credits

- **Protocol**: [AT Protocol](https://atproto.com) by Bluesky PBLLC
- **Inspiration**: The need for self-hosted migration tools in the federated ATProto ecosystem

## Acknowledgments

- Bluesky team for the AT Protocol specification
- The open-source community for Rails, Sidekiq, and supporting libraries
- Contributors who help improve this tool

---

**Made with ❤️ for the ATProto community**

For questions or support, please [open an issue](https://github.com/yourusername/u-haul/issues).
