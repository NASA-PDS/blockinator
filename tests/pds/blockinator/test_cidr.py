# -*- coding: utf-8 -*-
"""Tests for CIDR and TTL helpers."""
import pytest
from pds.blockinator.cidr import address_family
from pds.blockinator.cidr import normalize_cidr
from pds.blockinator.cidr import parse_ttl_seconds


def test_normalize_bare_ipv4():
    """Bare IPv4 addresses become /32."""
    assert normalize_cidr("203.0.113.10") == "203.0.113.10/32"


def test_normalize_ipv4_cidr():
    """IPv4 networks are canonicalized."""
    assert normalize_cidr("10.0.0.0/8") == "10.0.0.0/8"


def test_normalize_masks_host_bits():
    """Host bits in a CIDR are masked off."""
    assert normalize_cidr("10.1.2.3/8") == "10.0.0.0/8"


def test_normalize_ipv6():
    """Bare IPv6 addresses become /128."""
    assert normalize_cidr("2001:db8::1") == "2001:db8::1/128"


def test_normalize_rejects_empty():
    """Empty input is rejected."""
    with pytest.raises(ValueError, match="must not be empty"):
        normalize_cidr("  ")


def test_normalize_rejects_garbage():
    """Non-IP text is rejected."""
    with pytest.raises(ValueError, match="Invalid IP or CIDR"):
        normalize_cidr("not-an-ip")


def test_address_family():
    """Families are classified from the canonical CIDR."""
    assert address_family("203.0.113.10/32") == "IPV4"
    assert address_family("2001:db8::1/128") == "IPV6"


def test_parse_ttl_default_is_twelve_hours():
    """Omitted TTL defaults to 12 hours."""
    assert parse_ttl_seconds(None) == 12 * 3600


def test_parse_ttl_units():
    """Suffix units convert to seconds."""
    assert parse_ttl_seconds("6h") == 6 * 3600
    assert parse_ttl_seconds("30m") == 30 * 60
    assert parse_ttl_seconds("120s") == 120
    assert parse_ttl_seconds("2d") == 2 * 86400


def test_parse_ttl_no_expiry():
    """Zero, none, and --no-expiry all mean persistent."""
    assert parse_ttl_seconds("0") is None
    assert parse_ttl_seconds("none") is None
    assert parse_ttl_seconds("12h", no_expiry=True) is None


def test_parse_ttl_rejects_garbage():
    """Unknown TTL strings are rejected."""
    with pytest.raises(ValueError, match="Invalid TTL"):
        parse_ttl_seconds("forever")
