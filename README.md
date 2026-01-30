# u-haul 🚚

> Self-hosted ATProto account migration tool for Bluesky and the AT Protocol ecosystem

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Ruby 3.2.2](https://img.shields.io/badge/ruby-3.2.2-ruby.svg)](https://www.ruby-lang.org/)
[![Rails 7.1.3](https://img.shields.io/badge/rails-7.1.3-red.svg)](https://rubyonrails.org/)

**u-haul** is a standalone web application that helps you migrate your Bluesky/ATProto account from one Personal Data Server (PDS) to another. It provides a simple web interface to handle the entire migration process, including repository export/import, blob transfer, preferences migration, and PLC directory updates.

## Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
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

u-haul wraps the [goat](https://github.com/bluesky-social/goat) CLI tool and provides a web interface for ATProto account migrations. The migration happens in **7 sequential stages**:

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
- **goat CLI** (automatically installed in Docker)
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
   # Master key for Lockbox encryption
   openssl rand -hex 16

   # Active Record encryption keys (run 3 times)
   openssl rand -hex 32
   openssl rand -hex 32
   openssl rand -hex 32
   ```

   Add these to your `.env` file:
   ```bash
   MIGRATION_MASTER_KEY=<your-hex-16-key>
   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=<your-hex-32-key-1>
   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=<your-hex-32-key-2>
   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=<your-hex-32-key-3>
   ```

4. **Start the application:**
   ```bash
   docker compose up -d
   ```

5. **Access the web interface:**
   - Open http://localhost:3000
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
MIGRATION_MASTER_KEY=your-hex-16-key
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
MAX_CONCURRENT_MIGRATIONS=5  # Adjust based on available RAM

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
```

## Migration Process

### Starting a Migration

1. **Navigate to the web interface** at http://localhost:3000
2. **Fill out the migration form:**
   - Your email address (for notifications and PLC token)
   - Old account handle (e.g., `alice.bsky.social`)
   - Old account password
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

- **Minimum**: 4GB RAM (handles 1-2 concurrent migrations)
- **Recommended**: 8GB RAM (handles 5 concurrent migrations)
- **Optimal**: 16GB+ RAM (handles 10-15 concurrent migrations)

The application processes blobs sequentially to avoid memory exhaustion. Adjust `MAX_CONCURRENT_MIGRATIONS` based on your available RAM.

### Monitoring

- **Health endpoint**: `GET /up` (returns 200 OK if healthy)
- **Sidekiq logs**: `docker compose logs -f sidekiq`
- **Application logs**: `docker compose logs -f web`
- **Rails console**: `docker compose exec web rails console`

### Scheduled Jobs (Security)

The application automatically runs scheduled cleanup jobs via Sidekiq:

- **Credential Cleanup**: Every 6 hours - purges expired passwords and PLC tokens
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
- **CLI Wrapper**: goat v0.2.0

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

- **Credential Encryption**: Passwords and tokens encrypted with Lockbox (AES-256-GCM)
- **Auto-Expiration**: Passwords expire after 48h, PLC tokens after 1h
- **Automatic Cleanup**: Credentials are cleared immediately after successful migration
- **Background Purging**: Expired credentials are automatically purged every 6 hours
- **Token-Based Access**: Unguessable tokens (62^12 possibilities)
- **No Plain-Text Storage**: All sensitive data encrypted at rest
- **Data Minimization**: Credentials are deleted as soon as they're no longer needed (GDPR compliant)

### File Structure

```
u-haul/
├── app/
│   ├── controllers/     # MigrationsController (form, status, token submission)
│   ├── jobs/            # 7 Sidekiq jobs (migration stages)
│   ├── models/          # Migration model (state machine, encryption)
│   ├── services/        # GoatService (CLI wrapper + API client)
│   └── views/           # Web interface (form, status page)
├── config/              # Rails configuration
├── db/                  # Database migrations
├── docker-compose.yml   # Development stack
├── compose.yml.production  # Production stack with Caddy
├── Dockerfile           # Multi-stage build with goat CLI
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

- **Built with**: [goat](https://github.com/bluesky-social/goat) by Bluesky
- **Protocol**: [AT Protocol](https://atproto.com) by Bluesky PBLLC
- **Inspiration**: The need for self-hosted migration tools in the federated ATProto ecosystem

## Acknowledgments

- Bluesky team for the AT Protocol and goat CLI
- The open-source community for Rails, Sidekiq, and supporting libraries
- Contributors who help improve this tool

---

**Made with ❤️ for the ATProto community**

For questions or support, please [open an issue](https://github.com/yourusername/u-haul/issues).
