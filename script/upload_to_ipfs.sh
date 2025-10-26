#!/usr/bin/env bash
# Upload a file to IPFS and return its hash

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <file_path>" >&2
    exit 1
fi

FILE_PATH="$1"

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found." >&2
    exit 1
fi

if [ -z "$ARAGON_IPFS_AUTH_TOKEN" ]; then
    echo "Error: ARAGON_IPFS_AUTH_TOKEN environment variable is not set." >&2
    exit 1
fi

RESPONSE=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
    -H "Authorization: Bearer $ARAGON_IPFS_AUTH_TOKEN" \
    -F "file=@$FILE_PATH")


HASH=$(echo "$RESPONSE" | jq -r '.IpfsHash')

if [ -z "$HASH" ] || [ "$HASH" = "null" ]; then
    echo "Error: Failed to upload file to IPFS." >&2
    echo "Response: $RESPONSE" >&2
    exit 1
fi

echo "$HASH"
