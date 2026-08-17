#!/usr/bin/env bash
#
# fetch.sh - Fetch URL with whitelist failure detection
#
# Usage: ./fetch.sh <url>

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <url>" >&2
    exit 1
fi

URL="$1"
HOSTNAME=$(echo "$URL" | sed -E 's|^https?://||' | sed -E 's|/.*||' | sed -E 's|:.*||')

if [ -z "$HOSTNAME" ]; then
    echo "Error: Could not extract hostname from URL: $URL" >&2
    exit 1
fi

# Try to resolve DNS first
if ! dig +short "$HOSTNAME" >/dev/null 2>&1; then
    echo "❌ DNS resolution failed for: $HOSTNAME"
    exit 1
fi

IP=$(dig +short "$HOSTNAME" | head -1)

echo "📡 Fetching: $URL"
echo "   Resolved: $HOSTNAME → $IP"
echo ""

if curl -sSL -w "\n%{http_code}" --connect-timeout 10 --max-time 60 "$URL" 2>&1 | tail -1 | grep -qE "^[23]"; then
    echo "✅ Success"
else
    echo "❌ Connection failed to: $URL"
    echo ""
    echo "🔒 This looks like a NETWORK ISOLATION block."
    echo ""
    echo "✅ To allow access, add the domain to the host whitelist:"
    echo ""
    echo "   On the host (repo root):"
    echo "   sudo ./host/pi-sandbox-whitelist add $HOSTNAME"
    echo ""
    echo "The proxy reloads the file automatically - no VM restart needed."
    exit 1
fi
