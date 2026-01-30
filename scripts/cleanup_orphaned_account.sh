#!/bin/bash
# Script to clean up orphaned deactivated accounts from PDS
# Usage: ./cleanup_orphaned_account.sh <PDS_HOST> <DID> <ADMIN_PASSWORD>

set -e

PDS_HOST="${1:-https://pds.example.com}"
DID="${2:-did:plc:example123abc}"
ADMIN_PASSWORD="${3}"

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "Error: Admin password required"
  echo "Usage: $0 <PDS_HOST> <DID> <ADMIN_PASSWORD>"
  exit 1
fi

echo "Cleaning up orphaned account on $PDS_HOST"
echo "DID: $DID"
echo ""

# First, verify the account exists and is deactivated
echo "Checking account status..."
REPO_STATUS=$(curl -s "$PDS_HOST/xrpc/com.atproto.repo.describeRepo?repo=$DID" || echo '{}')
echo "Current status: $REPO_STATUS"
echo ""

# Login as admin (assumes admin account exists)
echo "Logging in as admin..."
ADMIN_SESSION=$(curl -s -X POST "$PDS_HOST/xrpc/com.atproto.server.createSession" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}")

ACCESS_TOKEN=$(echo "$ADMIN_SESSION" | jq -r '.accessJwt // empty')

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Error: Failed to authenticate as admin"
  echo "Response: $ADMIN_SESSION"
  exit 1
fi

echo "Admin authenticated successfully"
echo ""

# Delete the account
echo "Deleting orphaned account..."
DELETE_RESULT=$(curl -s -X POST "$PDS_HOST/xrpc/com.atproto.admin.deleteAccount" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"did\":\"$DID\"}")

echo "Delete result: $DELETE_RESULT"
echo ""

# Verify deletion
echo "Verifying deletion..."
VERIFY=$(curl -s "$PDS_HOST/xrpc/com.atproto.repo.describeRepo?repo=$DID" || echo '{}')
echo "After deletion: $VERIFY"
echo ""

if echo "$VERIFY" | grep -q "RepoNotFound"; then
  echo "✓ Account successfully deleted"
  exit 0
else
  echo "⚠ Account may still exist or deletion pending"
  exit 1
fi
