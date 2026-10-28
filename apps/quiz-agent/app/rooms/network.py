"""Which network a phone is on, as the server sees it (#212.1).

Two phones on one home Wi-Fi share the router's public IPv4 address, but over
IPv6 every phone has its own address (privacy addresses even rotate) and only
the /64 prefix is common. iOS on a dual-stack network prefers IPv6, and Happy
Eyeballs may put the host on one family and a guest on the other. So a phone's
network is described by up to two keys, one per family, and two phones are on
the same network when any key matches.

A request only shows the family it arrived on. The app learns its other key by
calling the probe endpoint on an IPv4-only and an IPv6-only hostname; each
answer is a short signed *net ticket* the app sends along when it creates or
looks for a room. Tickets are bound to the subject and expire, so a ticket
cannot be minted for someone else's network.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import ipaddress
import json
import time

TICKET_TTL_SECONDS = 600


def network_key(ip: str | None) -> str | None:
    """``v4:<address>`` or ``v6:<prefix>/64``; None for anything that is not
    a public address (local dev, a proxy that hid the client)."""
    try:
        addr = ipaddress.ip_address((ip or "").strip())
    except ValueError:
        return None
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    if not addr.is_global:
        return None
    if addr.version == 4:
        return f"v4:{addr}"
    net = ipaddress.ip_network(f"{addr}/64", strict=False)
    return f"v6:{net}"


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class NetTickets:
    def __init__(self, secret: str) -> None:
        self._key = hashlib.sha256(
            b"multiplayer-net-ticket:" + secret.encode()
        ).digest()

    def _sign(self, body: str) -> str:
        return _b64(hmac.new(self._key, body.encode(), hashlib.sha256).digest())

    def issue(self, subject_id: str, key: str, now: float | None = None) -> str:
        exp = int((now or time.time()) + TICKET_TTL_SECONDS)
        body = _b64(json.dumps({"s": subject_id, "k": key, "e": exp}).encode())
        return f"{body}.{self._sign(body)}"

    def verify(
        self, ticket: str, subject_id: str, now: float | None = None
    ) -> str | None:
        """The network key in a valid ticket for ``subject_id``, else None."""
        try:
            body, sig = ticket.split(".", 1)
            if not hmac.compare_digest(sig, self._sign(body)):
                return None
            data = json.loads(_unb64(body))
        except (ValueError, TypeError):
            return None
        if data.get("s") != subject_id or data.get("e", 0) < (now or time.time()):
            return None
        key = data.get("k")
        return key if isinstance(key, str) else None


def collect_keys(
    request_ip: str | None,
    tickets: list[str],
    subject_id: str,
    signer: NetTickets,
) -> dict[str, str]:
    """``{"v4": key, "v6": key}`` from the request itself plus valid tickets.
    The request's own address wins over a ticket of the same family."""
    keys: dict[str, str] = {}
    for ticket in tickets[:4]:
        key = signer.verify(ticket, subject_id)
        if key:
            keys.setdefault(key[:2], key)
    own = network_key(request_ip)
    if own:
        keys[own[:2]] = own
    return keys
