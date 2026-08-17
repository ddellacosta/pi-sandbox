#!/usr/bin/env python3
"""
mitmproxy addon that enforces a domain whitelist.

Intentionally non-decrypting: HTTPS domains are read from the CONNECT request
before TLS starts. The addon blocks any domain not listed in the whitelist file.
"""

import os
import time
from fnmatch import fnmatch
from mitmproxy import ctx, http

# Allow overriding via environment, but default to a host path outside the VM's
# writable workspace so the agent cannot modify the whitelist.
DEFAULT_WHITELIST = "/etc/pi-sandbox/whitelist.conf"
WHITELIST_FILE = os.environ.get("PI_SANDBOX_WHITELIST", DEFAULT_WHITELIST)
POLL_INTERVAL = 2  # seconds


class WhitelistAddon:
    def __init__(self):
        self.whitelist = set()
        self.last_mtime = 0
        self.last_check = 0

    def load_whitelist(self):
        """Reload whitelist domains from the config file."""
        if not os.path.exists(WHITELIST_FILE):
            self.whitelist = set()
            self.last_mtime = 0
            return

        try:
            mtime = os.path.getmtime(WHITELIST_FILE)
            if mtime == self.last_mtime:
                return

            domains = set()
            with open(WHITELIST_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    # Strip inline comments and whitespace.
                    domain = line.split()[0].lower()
                    if domain:
                        domains.add(domain)

            self.whitelist = domains
            self.last_mtime = mtime
            ctx.log.info(f"Loaded {len(domains)} whitelisted domain(s) from {WHITELIST_FILE}")
        except Exception as e:
            ctx.log.error(f"Failed to load whitelist: {e}")

    def is_allowed(self, hostname):
        """Check if hostname matches any whitelisted domain or its subdomains."""
        hostname = hostname.lower().rstrip(".")

        for allowed in self.whitelist:
            allowed = allowed.rstrip(".")
            if allowed == hostname:
                return True
            if hostname.endswith("." + allowed):
                return True
            # Optional glob support for convenience (e.g. *.example.com).
            if allowed.startswith("*.") and fnmatch(hostname, allowed):
                return True

        return False

    def check_whitelist(self, flow):
        """Poll for whitelist updates, then allow or block the flow."""
        if time.time() - self.last_check > POLL_INTERVAL:
            self.load_whitelist()
            self.last_check = time.time()

        host = flow.request.host
        if self.is_allowed(host):
            return

        ctx.log.warn(f"Blocked {flow.request.pretty_host}")
        flow.response = http.Response.make(
            403,
            b"Forbidden: domain not in whitelist",
            {"Content-Type": "text/plain"},
        )


# Global instance so all worker processes share the same loaded whitelist.
addon = WhitelistAddon()


def request(flow):
    addon.check_whitelist(flow)
