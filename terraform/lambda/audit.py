# -*- coding: utf-8 -*-
"""Write structured audit events from DynamoDB Streams to CloudWatch Logs."""
from __future__ import annotations

import json
from typing import Any


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Log add/remove/expire mutations from the blocklist table stream.

    Args:
        event: DynamoDB stream event.
        _context: Unused Lambda context.

    Returns:
        Count of records logged.
    """
    logged = 0
    for record in event.get("Records") or []:
        dynamo = record.get("dynamodb") or {}
        new_image = _unmarshal(dynamo.get("NewImage") or {})
        old_image = _unmarshal(dynamo.get("OldImage") or {})
        current = new_image or old_image
        payload = {
            "event": _classify(record.get("eventName"), old_image, new_image),
            "timestamp": record.get("dynamodb", {}).get("ApproximateCreationDateTime"),
            "cidr": current.get("cidr"),
            "action": current.get("action"),
            "reason": new_image.get("reason") or old_image.get("reason"),
            "operator": new_image.get("added_by") or old_image.get("added_by"),
            "source": new_image.get("source") or old_image.get("source"),
            "status": new_image.get("status") or old_image.get("status"),
            "streamEventName": record.get("eventName"),
        }
        print(json.dumps(payload, default=str))
        logged += 1
    return {"logged": logged}


def _classify(event_name: str | None, old_image: dict[str, Any], new_image: dict[str, Any]) -> str:
    """Map a stream record to add, remove, expire, or update."""
    old_status = old_image.get("status")
    new_status = new_image.get("status")
    if event_name == "INSERT":
        return "add"
    if event_name == "REMOVE":
        return "remove"
    if old_status == "ACTIVE" and new_status == "EXPIRED":
        return "expire"
    return "update"


def _unmarshal(image: dict[str, Any]) -> dict[str, Any]:
    """Flatten a DynamoDB stream image to native Python values."""
    out: dict[str, Any] = {}
    for key, attr in image.items():
        if "S" in attr:
            out[key] = attr["S"]
        elif "N" in attr:
            out[key] = attr["N"]
        elif "BOOL" in attr:
            out[key] = attr["BOOL"]
        elif "NULL" in attr:
            out[key] = None
    return out
