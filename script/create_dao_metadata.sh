#!/usr/bin/env bash
# Create DAO metadata JSON and upload to IPFS
# Usage: ./create_dao_metadata.sh <name> <description>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <name> <description>" >&2
    exit 1
fi

NAME="$1"
DESCRIPTION="$2"

# Create temporary JSON file
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Build JSON using jq (compacted)
jq -n -c \
    --arg name "$NAME" \
    --arg description "$DESCRIPTION" \
    '{name: $name, description: $description, links: []}' \
    > "$TEMP_FILE"

# Upload to IPFS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH=$("$SCRIPT_DIR/upload_to_ipfs.sh" "$TEMP_FILE")

# Return the hash
echo "$HASH"
