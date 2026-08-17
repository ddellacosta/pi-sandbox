#!/usr/bin/env bash
#
# check-whitelist.sh - Check if a domain is accessible
#
# Usage: ./check-whitelist.sh <domain>

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <domain>" >&2
    exit 1
fi

DOMAIN="$1"

echo "🔍 Checking: $DOMAIN"
echo ""

IP=$(dig +short "$DOMAIN" | head -1)

if [ -z "$IP" ]; then
    echo "❌ DNS resolution failed"
    exit 1
fi

echo "✅ DNS: $DOMAIN → $IP"

if curl -sS --connect-timeout 5 "https://$DOMAIN" >/dev/null 2>&1; then
    echo "✅ HTTPS: Accessible"
    exit 0
fi

if curl -sS --connect-timeout 5 "http://$DOMAIN" >/dev/null 2>&1; then
    echo "✅ HTTP: Accessible"
    exit 0
fi

echo "❌ HTTPS/HTTP: Connection failed"
echo ""
echo "Status: BLOCKED by sandbox proxy or firewall."
echo ""
echo "To allow access, add to whitelist (on the host, repo root):"
echo ""
echo "   sudo ./host/pi-sandbox-whitelist add $DOMAIN"
echo ""
echo "The proxy reloads the file automatically - no VM restart needed."

exit 1
