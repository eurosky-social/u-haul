#!/bin/bash
# Script to clean up orphaned deactivated accounts from PDS via direct database access
# This requires SSH access to the PDS server
# Usage: ./cleanup_orphaned_account_db.sh <DID>

set -e

DID="${1:-did:plc:example123abc}"
PDS_HOST="pds.example.com"

echo "Cleaning up orphaned account via database"
echo "PDS: $PDS_HOST"
echo "DID: $DID"
echo ""

# SSH into PDS server and execute database cleanup
ssh root@"$PDS_HOST" bash << EOF
  set -e

  echo "Checking for account in database..."
  docker exec pds psql -U postgres -d pds -c "
    SELECT did, handle, takedown_ref, created_at
    FROM actor
    WHERE did = '$DID';
  "

  echo ""
  echo "Checking repo_root..."
  docker exec pds psql -U postgres -d pds -c "
    SELECT did, cid, rev, created_at
    FROM repo_root
    WHERE did = '$DID';
  "

  echo ""
  echo "Checking blob count..."
  docker exec pds psql -U postgres -d pds -c "
    SELECT COUNT(*) as blob_count
    FROM repo_blob
    WHERE did = '$DID';
  "

  echo ""
  read -p "Delete this account and all associated data? (yes/no): " confirm

  if [ "\$confirm" = "yes" ]; then
    echo ""
    echo "Deleting account data..."

    # Delete in correct order (respecting foreign keys)
    docker exec pds psql -U postgres -d pds << SQL
      BEGIN;

      -- Delete blobs
      DELETE FROM repo_blob WHERE did = '$DID';

      -- Delete repo blocks
      DELETE FROM repo_block WHERE did = '$DID';

      -- Delete repo root
      DELETE FROM repo_root WHERE did = '$DID';

      -- Delete record entries
      DELETE FROM record WHERE did = '$DID';

      -- Delete actor
      DELETE FROM actor WHERE did = '$DID';

      COMMIT;
SQL

    echo ""
    echo "✓ Account deleted successfully"

    echo ""
    echo "Verifying deletion..."
    docker exec pds psql -U postgres -d pds -c "
      SELECT did FROM actor WHERE did = '$DID';
    "

  else
    echo "Deletion cancelled"
    exit 1
  fi
EOF

echo ""
echo "Cleanup complete. You can now retry the migration."
