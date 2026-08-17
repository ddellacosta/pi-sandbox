#!/usr/bin/env bash
#
# whitelist-helper.sh - Generate whitelist commands for one or more domains.
#
# Usage: ./whitelist-helper.sh <domain1> [domain2] [domain3] ...

if [ $# -eq 0 ]; then
    echo "Usage: $0 <domain1> [domain2] [domain3] ..."
    echo ""
    echo "Generates the host command to add domains to the sandbox whitelist."
    exit 1
fi

echo "📋 Run these commands on the host (repo root):"
echo ""
for domain in "$@"; do
    # Extract base domain (remove subdomains for cleaner config).
    BASE_DOMAIN=$(echo "$domain" | grep -oE '[^/]+\.[^/]+$' | head -1)
    if [ -n "$BASE_DOMAIN" ]; then
        echo "sudo ./host/pi-sandbox-whitelist add $BASE_DOMAIN  # $domain"
    else
        echo "sudo ./host/pi-sandbox-whitelist add $domain"
    fi
done
echo ""
echo "The proxy reloads the whitelist automatically - no VM restart needed."
