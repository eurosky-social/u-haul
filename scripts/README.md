# Cleanup Scripts for Orphaned Accounts

## Problem: "AlreadyExists" Error

When a migration fails after creating a deactivated account on the target PDS but before completing the migration, the account remains in the PDS database. This causes subsequent migration attempts to fail with:

```
ERROR: AlreadyExists: Repo already exists
```

However, when you check the PDS web interface or API, the account appears to not exist because it's deactivated.

## Detection

### Check if an account is orphaned:

```bash
# Via rake task (from inside docker container)
docker compose exec web rake migration:check_orphaned[https://pds.example.com,did:plc:example123abc]

# Via curl
curl -s "https://pds.example.com/xrpc/com.atproto.repo.describeRepo?repo=did:plc:example123abc"
```

**Orphaned account response:**
```json
{"error":"RepoDeactivated","message":"Repo has been deactivated: did:plc:example123abc"}
```

**No account response:**
```json
{"error":"RepoNotFound","message":"Could not find repo: did:plc:example123abc"}
```

## Cleanup Options

### Option 1: Direct Database Cleanup (Recommended)

This script SSH's into the PDS server and removes the orphaned account from the database.

**Requirements:**
- SSH access to the PDS server
- Root or sudo access
- Docker access on the PDS server

**Usage:**
```bash
cd scripts
chmod +x cleanup_orphaned_account_db.sh
./cleanup_orphaned_account_db.sh did:plc:example123abc
```

The script will:
1. Connect to the PDS server via SSH
2. Show the orphaned account data
3. Ask for confirmation
4. Delete the account and all associated data (blobs, records, etc.)
5. Verify deletion

### Option 2: PDS Admin API (If Admin Access Available)

This script uses the PDS admin API to delete the account.

**Requirements:**
- Admin account on the target PDS
- Admin password

**Usage:**
```bash
cd scripts
chmod +x cleanup_orphaned_account.sh
./cleanup_orphaned_account.sh \
  https://pds.example.com \
  did:plc:example123abc \
  YOUR_ADMIN_PASSWORD
```

### Option 3: Rake Task (Interactive)

Run from inside the eurosky-migration docker container:

```bash
# List all failed migrations with AlreadyExists errors
docker compose exec web bundle exec rake migration:list_orphaned_migrations

# Check specific migration (note: quote the task name to avoid shell glob expansion)
docker compose exec web bundle exec rake 'migration:check_orphaned[https://pds.example.com,did:plc:xxxxx]'

# Reset migration to retry (after cleanup)
docker compose exec web bundle exec rake 'migration:reset_migration[EURO-XXXXXXXX]'
```

## Full Recovery Workflow

If you encounter the "AlreadyExists" error:

1. **Identify the orphaned account:**
   ```bash
   docker compose exec web bundle exec rake migration:list_orphaned_migrations
   ```

2. **Verify it's truly orphaned:**
   ```bash
   curl -s "https://YOUR_PDS/xrpc/com.atproto.repo.describeRepo?repo=YOUR_DID"
   ```

   Look for `"error":"RepoDeactivated"`

3. **Clean up the orphaned account:**
   ```bash
   cd scripts
   ./cleanup_orphaned_account_db.sh YOUR_DID
   ```

4. **Reset the migration:**
   ```bash
   docker compose exec web bundle exec rake 'migration:reset_migration[YOUR_TOKEN]'
   ```

5. **Monitor the retry:**
   ```bash
   docker compose logs -f sidekiq
   ```

## Prevention

The migration system now automatically detects "AlreadyExists" errors and provides clear instructions in the error message. Future enhancements may include:

- Automatic cleanup with user confirmation
- Pre-flight check before creating account
- Idempotent account creation

## Database Schema Reference

The PDS uses PostgreSQL with these relevant tables:

- `actor` - Account metadata (DID, handle, email)
- `repo_root` - Repository root CID and revision
- `repo_block` - Repository blocks (commit history)
- `repo_blob` - Blob metadata (images, videos, etc.)
- `record` - Individual records (posts, likes, follows, etc.)

All are linked by DID and must be deleted in the correct order to respect foreign key constraints.

## Troubleshooting

### SSH Connection Refused
```
ssh: connect to host pds.example.com port 22: Connection refused
```

**Solution:** Update the script with the correct SSH hostname or use the admin API method instead.

### Admin Authentication Failed
```
Error: Failed to authenticate as admin
```

**Solution:** Verify the admin account exists and the password is correct. You may need to create an admin account on the PDS first.

### Database Access Denied
```
psql: FATAL: database "pds" does not exist
```

**Solution:** Verify the PDS is running and the database name is correct (may be `bluesky` or `pds` depending on version).

## See Also

- [Migration Flow Documentation](../docs/MIGRATION_FLOW.md)
- [Error Handling Documentation](../docs/ERROR_HANDLING.md)
- [PDS Admin Guide](https://github.com/bluesky-social/pds)
