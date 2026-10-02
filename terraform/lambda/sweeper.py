# -*- coding: utf-8 -*-
"""Expire ACTIVE blocklist rows whose TTL has passed and enqueue REMOVE."""
from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

import boto3
from boto3.dynamodb.conditions import Attr, Key
from botocore.exceptions import ClientError

MESSAGE_GROUP_ID = "ipset"


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    """Mark expired ACTIVE items EXPIRED and enqueue IPSet removals.

    Args:
        event: EventBridge scheduled event (unused).
        _context: Unused Lambda context.

    Returns:
        Counts of expired items processed.
    """
    table_name = os.environ["TABLE_NAME"]
    queue_url = os.environ["QUEUE_URL"]
    table = boto3.resource("dynamodb").Table(table_name)
    sqs = boto3.client("sqs")
    now = int(time.time())
    removed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    expired = 0
    kwargs: dict[str, Any] = {
        "IndexName": "status-expires_at-index",
        "KeyConditionExpression": Key("status").eq("ACTIVE") & Key("expires_at").lte(now),
    }
    while True:
        response = table.query(**kwargs)
        for item in response.get("Items") or []:
            cidr = item["cidr"]
            try:
                table.update_item(
                    Key={"cidr": cidr},
                    UpdateExpression="SET #status = :expired, removed_at = :removed_at",
                    ConditionExpression=Attr("status").eq("ACTIVE"),
                    ExpressionAttributeNames={"#status": "status"},
                    ExpressionAttributeValues={":expired": "EXPIRED", ":removed_at": removed_at},
                )
            except ClientError as exc:
                if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                    raise
                continue
            sqs.send_message(
                QueueUrl=queue_url,
                MessageBody=json.dumps(
                    {"op": "REMOVE", "cidr": cidr, "request_id": str(uuid4()), "source": "sweeper"}
                ),
                MessageGroupId=MESSAGE_GROUP_ID,
            )
            print(json.dumps({"event": "expired", "cidr": cidr, "expires_at": int(item["expires_at"])}))
            expired += 1
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        kwargs["ExclusiveStartKey"] = last_key
    return {"expired": expired}
