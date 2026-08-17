#!/usr/bin/env python3
"""
mitmproxy addon that enforces a domain whitelist.

Non-decrypting: the whitelist check runs on the CONNECT request (for HTTPS)
or the plain HTTP request (for HTTP). If a domain is not allowed, the proxy
returns 403 before any TLS handshake or tunnel is established.

For allowed domains, mitmproxy is configured to pass TLS through without
decrypting it, so no CA needs to be installed in the VM.
"""

import os
import time
from fnmatch import fnmatch
from mitmproxy import ctx, http

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
                    domain = line.split()[0].lower()
                    if domain:
                        domains.add(domain)

            self.whitelist = domains
            self.last_mtime = mtime
            ctx.log.info(f"Loaded {len(domains)} whitelisted domain(s) from {WHITELIST_FILE}")
        except Exception as e:
            ctx.log.error(f"Failed to load whitelist: {e}")

    def maybe_reload(self):
        if time.time() - self.last_check > POLL_INTERVAL:
            self.load_whitelist()
            self.last_check = time.time()

    def is_allowed(self, hostname):
        """Check if hostname matches any whitelisted domain or its subdomains."""
        hostname = hostname.lower().rstrip(".")

        for allowed in self.whitelist:
            allowed = allowed.rstrip(".")
            if allowed == hostname:
                return True
            if hostname.endswith("." + allowed):
                return True
            if allowed.startswith("*.") and fnmatch(hostname, allowed):
                return True

        return False

    def block(self, flow, host):
        ctx.log.warn(f"Blocked {host}")
        flow.response = http.Response.make(
            403,
            b"Forbidden: domain not in whitelist",
            {"Content-Type": "text/plain"},
        )


addon = WhitelistAddon()


def http_connect(flow):
    """Block or allow HTTPS CONNECT requests before any TLS handshake."""
    addon.maybe_reload()
    host = flow.request.host
    if not addon.is_allowed(host):
        addon.block(flow, host)


def request(flow):
    """Block or allow plain HTTP requests."""
    addon.maybe_reload()
    host = flow.request.host
    if not addon.is_allowed(host):
        addon.block(flow, host)
