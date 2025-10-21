#!/usr/bin/env bash
# Upload a file to IPFS and return its hash

set -e

# Check if a file argument was provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <file_path>" >&2
    exit 1
fi

FILE_PATH="$1"

# Check if file exists
if [ ! -f "$FILE_PATH" ]; then
    echo "Error: File '$FILE_PATH' not found." >&2
    exit 1
fi

# Check if ipfs command is available
if ! command -v ipfs &> /dev/null; then
    echo "Error: ipfs command not found. Please install IPFS." >&2
    echo "Install with: brew install ipfs" >&2
    exit 1
fi

# Check if IPFS daemon is running by trying to connect
if ! ipfs swarm peers &> /dev/null; then
    echo "Error: Could not connect to IPFS daemon." >&2
    echo "Make sure IPFS is running (e.g., run 'ipfs daemon' in another terminal)" >&2
    exit 1
fi

# Upload the file and extract the hash
HASH=$(ipfs add -Q "$FILE_PATH")

# Print the hash
echo "$HASH"
