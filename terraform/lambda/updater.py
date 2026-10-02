# -*- coding: utf-8 -*-
"""Single-writer Lambda that applies batched ADD/REMOVE ops to WAF IPSets."""
from __future__ import annotations

import ipaddress
import json
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

VALID_OPS = ("ADD", "REMOVE")


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Apply a batch of SQS FIFO mutations to the CloudFront WAF IPSets.

    Args:
        event: SQS event with ``Records``.
        _context: Unused Lambda context.

    Returns:
        Partial batch failure response for SQS.
    """
    waf = boto3.client("wafv2", region_name=os.environ.get("WAF_REGION", "us-east-1"))
    scope = os.environ.get("WAF_SCOPE", "CLOUDFRONT")
    sets = {
        "IPV4": {"id": os.environ["IPV4_IP_SET_ID"], "name": os.environ["IPV4_IP_SET_NAME"]},
        "IPV6": {"id": os.environ["IPV6_IP_SET_ID"], "name": os.environ["IPV6_IP_SET_NAME"]},
    }

    planned, parsed_ids, failures = _plan_mutations(event.get("Records") or [])

    try:
        _apply_plan(waf, scope, sets, planned)
    except ClientError as exc:
        print(json.dumps({"event": "update_failed", "error": str(exc)}))
        failures.extend({"itemIdentifier": message_id} for message_id in parsed_ids)

    return {"batchItemFailures": failures}


def _plan_mutations(
    records: list[dict[str, Any]],
) -> tuple[dict[str, dict[str, set[str]]], list[str], list[dict[str, str]]]:
    """Collapse the SQS records into a per-family set of ADD/REMOVE mutations.

    Args:
        records: ``Records`` entries from the SQS event.

    Returns:
        The planned mutations, the message IDs that parsed cleanly, and the
        partial batch failures for the records that did not.
    """
    planned: dict[str, dict[str, set[str]]] = {
        "IPV4": {"ADD": set(), "REMOVE": set()},
        "IPV6": {"ADD": set(), "REMOVE": set()},
    }
    parsed_ids: list[str] = []
    failures: list[dict[str, str]] = []

    for record in records:
        message_id = record["messageId"]
        try:
            family, op, cidr = _parse_record(record)
        except (KeyError, TypeError, ValueError) as exc:
            print(json.dumps({"event": "parse_error", "messageId": message_id, "error": str(exc)}))
            failures.append({"itemIdentifier": message_id})
            continue
        parsed_ids.append(message_id)
        planned[family][op].add(cidr)
        planned[family]["ADD" if op == "REMOVE" else "REMOVE"].discard(cidr)

    return planned, parsed_ids, failures


def _parse_record(record: dict[str, Any]) -> tuple[str, str, str]:
    """Extract the address family, operation, and normalized CIDR from a record.

    Args:
        record: A single SQS record.

    Returns:
        Tuple of family (``IPV4``/``IPV6``), op, and normalized CIDR.

    Raises:
        KeyError: The body is missing a required field.
        TypeError: A field holds a type the parsers reject.
        ValueError: The body is not JSON, the op is unknown, or the CIDR is invalid.
    """
    body = json.loads(record["body"])
    op = str(body["op"]).upper()
    if op not in VALID_OPS:
        raise ValueError(f"Unknown op {op}")
    network = ipaddress.ip_network(body["cidr"], strict=False)
    family = "IPV4" if network.version == 4 else "IPV6"
    return family, op, str(network)


def _apply_plan(
    waf: Any,
    scope: str,
    sets: dict[str, dict[str, str]],
    planned: dict[str, dict[str, set[str]]],
) -> None:
    """Push the planned mutations to each IP set that has pending work.

    Args:
        waf: The wafv2 client.
        scope: WAF scope, e.g. ``CLOUDFRONT``.
        sets: Per-family IP set ``id`` and ``name``.
        planned: Per-family ADD/REMOVE mutations.
    """
    for family, spec in sets.items():
        to_add = sorted(planned[family]["ADD"])
        to_delete = sorted(planned[family]["REMOVE"])
        if to_add or to_delete:
            _update_ip_set(waf, scope, spec["name"], spec["id"], to_add, to_delete)


def _update_ip_set(
    waf: Any,
    scope: str,
    name: str,
    ip_set_id: str,
    to_add: list[str],
    to_delete: list[str],
    attempts: int = 5,
) -> None:
    """Replace the IP set address list, retrying on LockToken conflicts.

    Lambda's bundled botocore still requires the full ``Addresses`` list.
    ``AddressesToAdd`` / ``AddressesToDelete`` are rejected as unknown
    parameters, which is why this does get-then-put instead of a delta update.
    """
    for attempt in range(attempts):
        current = waf.get_ip_set(Name=name, Scope=scope, Id=ip_set_id)
        token = current["LockToken"]
        addresses = set(current["IPSet"].get("Addresses") or [])
        addresses.update(to_add)
        addresses.difference_update(to_delete)
        try:
            waf.update_ip_set(
                Name=name,
                Scope=scope,
                Id=ip_set_id,
                Addresses=sorted(addresses),
                LockToken=token,
            )
            print(
                json.dumps(
                    {
                        "event": "ipset_updated",
                        "name": name,
                        "added": to_add,
                        "removed": to_delete,
                    }
                )
            )
            return
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code != "WAFOptimisticLockException" or attempt == attempts - 1:
                raise
            time.sleep(0.2 * (attempt + 1))
