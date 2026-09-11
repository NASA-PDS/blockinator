# -*- coding: utf-8 -*-
"""Console script for the PDS IP/CIDR blocklist."""
from __future__ import annotations

import argparse
import json
import sys
from typing import Optional
from typing import Sequence

from .client import BlocklistClient
from .client import STATUS_ACTIVE


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Run ``pds-blockinator``.

    Args:
        argv: Optional argument list; defaults to ``sys.argv[1:]``.

    Returns:
        Process exit code.
    """
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        client = BlocklistClient.from_environment(
            table_name=args.table,
            queue_url=args.queue,
            ssm_prefix=args.ssm_prefix,
            profile=args.profile,
        )
        if args.command == "add":
            item = client.add(
                args.cidr,
                args.reason,
                ttl=args.ttl,
                no_expiry=args.no_expiry,
            )
            print(json.dumps(item, default=str))
        elif args.command == "remove":
            item = client.remove(args.cidr, reason=args.reason)
            print(json.dumps(item, default=str))
        elif args.command == "list":
            items = client.list_entries(status=args.status)
            print(json.dumps(items, default=str, indent=2))
        else:
            parser.error(f"Unknown command: {args.command}")
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001
        print(f"pds-blockinator failed: {exc}", file=sys.stderr)
        return 1
    return 0


def _build_parser() -> argparse.ArgumentParser:
    """Build the top-level argument parser."""
    parser = argparse.ArgumentParser(
        prog="pds-blockinator",
        description="Manage the operator IP/CIDR blocklist without WAF console access.",
    )
    parser.add_argument(
        "--profile",
        metavar="PROFILE",
        help="AWS named profile (overrides AWS_PROFILE)",
    )
    parser.add_argument("--table", help="DynamoDB table name (or PDS_BLOCKLIST_TABLE)")
    parser.add_argument("--queue", help="SQS FIFO queue URL (or PDS_BLOCKLIST_QUEUE_URL)")
    parser.add_argument(
        "--ssm-prefix",
        help="SSM prefix used when --table/--queue are omitted (default /pds/cds-infra/ip-blocklist)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add", help="Block an IP or CIDR")
    add.add_argument("cidr", help="IPv4/IPv6 address or CIDR")
    add.add_argument("--reason", required=True, help="Why this address is being blocked")
    add.add_argument("--ttl", help="Expiry window such as 12h, 6h, 30m (default 12h)")
    add.add_argument("--no-expiry", action="store_true", help="Persistent block (no TTL)")

    remove = sub.add_parser("remove", help="Unblock an IP or CIDR")
    remove.add_argument("cidr", help="IPv4/IPv6 address or CIDR")
    remove.add_argument("--reason", help="Optional note recorded on the item")

    list_cmd = sub.add_parser("list", help="List blocklist entries")
    list_cmd.add_argument(
        "--status",
        default=STATUS_ACTIVE,
        choices=(STATUS_ACTIVE, "EXPIRED", "ALL"),
        help="Filter by status (default ACTIVE)",
    )
    return parser


if __name__ == "__main__":
    sys.exit(main())
