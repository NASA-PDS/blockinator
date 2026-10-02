# -*- coding: utf-8 -*-
"""CIDR and TTL helpers for the IP blocklist."""
from __future__ import annotations

import ipaddress
import re
from typing import Optional

_TTL_PATTERN = re.compile(r"^(?P<value>\d+)(?P<unit>[smhd])?$", re.IGNORECASE)

_UNIT_SECONDS = {
    "s": 1,
    "m": 60,
    "h": 3600,
    "d": 86400,
}

DEFAULT_TTL_SECONDS = 12 * 3600


def normalize_cidr(value: str) -> str:
    """Return a canonical IPv4 or IPv6 CIDR string.

    Bare addresses become /32 (IPv4) or /128 (IPv6). Host bits in a network
    address are masked off.

    Args:
        value: An IP address or CIDR, for example ``203.0.113.10`` or
            ``10.0.0.0/8``.

    Returns:
        Canonical CIDR such as ``203.0.113.10/32``.

    Raises:
        ValueError: If ``value`` is not a valid IP or CIDR.
    """
    text = value.strip()
    if not text:
        raise ValueError("CIDR must not be empty")
    try:
        if "/" in text:
            return str(ipaddress.ip_network(text, strict=False))
        address = ipaddress.ip_address(text)
        prefix = 32 if address.version == 4 else 128
        return str(ipaddress.ip_network(f"{address}/{prefix}", strict=False))
    except ValueError as exc:
        raise ValueError(f"Invalid IP or CIDR: {value}") from exc


def address_family(cidr: str) -> str:
    """Return ``IPV4`` or ``IPV6`` for a canonical CIDR.

    Args:
        cidr: Canonical CIDR string.

    Returns:
        ``IPV4`` or ``IPV6``.
    """
    network = ipaddress.ip_network(cidr, strict=False)
    return "IPV4" if network.version == 4 else "IPV6"


def parse_ttl_seconds(text: Optional[str], *, no_expiry: bool = False) -> Optional[int]:
    """Parse a TTL into seconds, or ``None`` for a persistent entry.

    Accepted forms: ``12h``, ``6h``, ``30m``, ``120s``, a bare integer
    (seconds), or ``0`` / ``none`` for no expiry. When ``text`` is omitted the
    default is 12 hours.

    Args:
        text: Operator-supplied TTL, or ``None`` to use the default.
        no_expiry: If true, ignore ``text`` and return ``None``.

    Returns:
        TTL in seconds, or ``None`` if the entry should not expire.

    Raises:
        ValueError: If ``text`` is not a recognized TTL.
    """
    if no_expiry:
        return None
    if text is None:
        return DEFAULT_TTL_SECONDS
    stripped = text.strip().lower()
    if stripped in {"0", "none"}:
        return None
    match = _TTL_PATTERN.match(stripped)
    if match is None:
        raise ValueError(f"Invalid TTL: {text} (use 12h, 30m, 120s, or 0 for no expiry)")
    raw = int(match.group("value"))
    unit = match.group("unit")
    if unit is None:
        return raw
    return raw * _UNIT_SECONDS[unit]
