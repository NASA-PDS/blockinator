# -*- coding: utf-8 -*-
"""DynamoDB source of truth and SQS mutation bus for the IP blocklist."""
from __future__ import annotations

import json
import os
from datetime import datetime
from datetime import timezone
from typing import Any
from typing import Optional
from uuid import uuid4

import boto3
from botocore.exceptions import ClientError
from .cidr import address_family
from .cidr import normalize_cidr
from .cidr import parse_ttl_seconds

DEFAULT_SSM_PREFIX = "/pds/cds-infra/ip-blocklist"
MESSAGE_GROUP_ID = "ipset"
SOURCE_MANUAL = "MANUAL"
ACTION_BLOCK = "BLOCK"
STATUS_ACTIVE = "ACTIVE"
STATUS_EXPIRED = "EXPIRED"
ATTR_NAMES_STATUS = {"#status": "status"}  # DynamoDB reserved-word alias for status


class BlocklistClient:
    """Write blocklist entries to DynamoDB and enqueue WAF IPSet mutations."""

    def __init__(
        self,
        table_name: str,
        queue_url: str,
        *,
        dynamodb_resource: Any = None,
        sqs_client: Any = None,
        sts_client: Any = None,
        profile: Optional[str] = None,
    ) -> None:
        """Create a client bound to a table and FIFO queue.

        Args:
            table_name: DynamoDB table name.
            queue_url: SQS FIFO queue URL.
            dynamodb_resource: Optional boto3 DynamoDB resource.
            sqs_client: Optional boto3 SQS client.
            sts_client: Optional boto3 STS client.
            profile: Optional AWS named profile; overrides ``AWS_PROFILE``.
        """
        if dynamodb_resource is None or sqs_client is None or sts_client is None:
            session = boto3.session.Session(profile_name=profile)
            dynamodb_resource = dynamodb_resource or session.resource("dynamodb")
            sqs_client = sqs_client or session.client("sqs")
            sts_client = sts_client or session.client("sts")
        self._table = dynamodb_resource.Table(table_name)
        self._sqs = sqs_client
        self._sts = sts_client
        self._queue_url = queue_url

    @classmethod
    def from_environment(
        cls,
        *,
        table_name: Optional[str] = None,
        queue_url: Optional[str] = None,
        ssm_prefix: Optional[str] = None,
        ssm_client: Any = None,
        profile: Optional[str] = None,
    ) -> "BlocklistClient":
        """Build a client from flags, environment variables, or SSM.

        Resolution order for table and queue: explicit arguments, then
        ``PDS_BLOCKLIST_TABLE`` / ``PDS_BLOCKLIST_QUEUE_URL``, then SSM
        parameters under ``ssm_prefix`` (default
        ``/pds/cds-infra/ip-blocklist``).

        AWS credentials use ``profile`` when given, otherwise the default
        boto3 chain (including ``AWS_PROFILE``).

        Args:
            table_name: Optional DynamoDB table name.
            queue_url: Optional SQS queue URL.
            ssm_prefix: Optional SSM prefix for lookups.
            ssm_client: Optional boto3 SSM client.
            profile: Optional AWS named profile; overrides ``AWS_PROFILE``.

        Returns:
            A configured ``BlocklistClient``.

        Raises:
            ValueError: If table name or queue URL cannot be resolved.
        """
        prefix = ssm_prefix or os.environ.get("PDS_BLOCKLIST_SSM_PREFIX", DEFAULT_SSM_PREFIX)
        resolved_table = table_name or os.environ.get("PDS_BLOCKLIST_TABLE")
        resolved_queue = queue_url or os.environ.get("PDS_BLOCKLIST_QUEUE_URL")
        session = boto3.session.Session(profile_name=profile)
        if not resolved_table or not resolved_queue:
            ssm = ssm_client or session.client("ssm")
            if not resolved_table:
                resolved_table = _ssm_get(ssm, f"{prefix}/table-name")
            if not resolved_queue:
                resolved_queue = _ssm_get(ssm, f"{prefix}/queue-url")
        if not resolved_table or not resolved_queue:
            raise ValueError(
                "Could not resolve table name and queue URL. Pass --table/--queue, "
                "set PDS_BLOCKLIST_TABLE and PDS_BLOCKLIST_QUEUE_URL, or publish SSM "
                f"parameters under {prefix}."
            )
        return cls(
            resolved_table,
            resolved_queue,
            dynamodb_resource=session.resource("dynamodb"),
            sqs_client=session.client("sqs"),
            sts_client=session.client("sts"),
        )

    def add(
        self,
        cidr: str,
        reason: str,
        *,
        ttl: Optional[str] = None,
        no_expiry: bool = False,
        source: str = SOURCE_MANUAL,
        added_by: Optional[str] = None,
    ) -> dict[str, Any]:
        """Add or refresh a BLOCK entry and enqueue an IPSet ADD.

        Args:
            cidr: IP or CIDR to block.
            reason: Human-readable reason recorded in the audit trail.
            ttl: Optional TTL such as ``12h``. Default is 12 hours.
            no_expiry: If true, the entry does not expire.
            source: ``MANUAL`` or ``AUTOMATED``.
            added_by: Optional principal; STS caller identity is used if omitted.

        Returns:
            The item written to DynamoDB.

        Raises:
            ValueError: If ``reason`` is empty or ``cidr`` is invalid.
        """
        if not reason or not reason.strip():
            raise ValueError("A --reason is required")
        canonical = normalize_cidr(cidr)
        ttl_seconds = parse_ttl_seconds(ttl, no_expiry=no_expiry)
        now = datetime.now(timezone.utc)
        item: dict[str, Any] = {
            "cidr": canonical,
            "action": ACTION_BLOCK,
            "reason": reason.strip(),
            "added_by": added_by or self._caller_identity(),
            "added_at": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "source": source,
            "status": STATUS_ACTIVE,
            "address_family": address_family(canonical),
        }
        if ttl_seconds is not None:
            item["expires_at"] = int(now.timestamp()) + ttl_seconds
        self._table.put_item(Item=item)
        self._enqueue("ADD", canonical)
        return item

    def remove(self, cidr: str, *, reason: Optional[str] = None) -> dict[str, Any]:
        """Mark an entry expired and enqueue an IPSet REMOVE.

        Args:
            cidr: IP or CIDR to unblock.
            reason: Optional note recorded on the item.

        Returns:
            The updated item, or a tombstone if the CIDR was not in the table.
        """
        canonical = normalize_cidr(cidr)
        now = datetime.now(timezone.utc)
        values: dict[str, Any] = {
            ":expired": STATUS_EXPIRED,
            ":removed_at": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        }
        update = "SET #status = :expired, removed_at = :removed_at"
        if reason:
            update += ", removal_reason = :removal_reason"
            values[":removal_reason"] = reason.strip()
        item: dict[str, Any] = {"cidr": canonical, "status": STATUS_EXPIRED}
        try:
            response = self._table.update_item(
                Key={"cidr": canonical},
                UpdateExpression=update,
                ConditionExpression="attribute_exists(cidr)",
                ExpressionAttributeNames=ATTR_NAMES_STATUS,
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW",
            )
            item = dict(response.get("Attributes") or item)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
        self._enqueue("REMOVE", canonical)
        return item

    def list_entries(self, *, status: str = STATUS_ACTIVE) -> list[dict[str, Any]]:
        """Return blocklist items, optionally filtered by status.

        Args:
            status: ``ACTIVE``, ``EXPIRED``, or ``ALL``.

        Returns:
            Matching DynamoDB items.
        """
        if status == "ALL":
            response = self._table.scan()
            items = list(response.get("Items") or [])
            while response.get("LastEvaluatedKey"):
                response = self._table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
                items.extend(response.get("Items") or [])
            return items
        response = self._table.scan(
            FilterExpression="#status = :status",
            ExpressionAttributeNames=ATTR_NAMES_STATUS,
            ExpressionAttributeValues={":status": status},
        )
        items = list(response.get("Items") or [])
        while response.get("LastEvaluatedKey"):
            response = self._table.scan(
                ExclusiveStartKey=response["LastEvaluatedKey"],
                FilterExpression="#status = :status",
                ExpressionAttributeNames=ATTR_NAMES_STATUS,
                ExpressionAttributeValues={":status": status},
            )
            items.extend(response.get("Items") or [])
        return items

    def _enqueue(self, op: str, cidr: str) -> None:
        """Send an ADD or REMOVE mutation to the FIFO queue."""
        self._sqs.send_message(
            QueueUrl=self._queue_url,
            MessageBody=json.dumps({"op": op, "cidr": cidr, "request_id": str(uuid4())}),
            MessageGroupId=MESSAGE_GROUP_ID,
        )

    def _caller_identity(self) -> str:
        """Return the IAM principal ARN of the current caller."""
        return str(self._sts.get_caller_identity()["Arn"])


def _ssm_get(ssm_client: Any, name: str) -> Optional[str]:
    """Return an SSM parameter value, or ``None`` if it does not exist."""
    try:
        return str(ssm_client.get_parameter(Name=name)["Parameter"]["Value"])
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ParameterNotFound":
            return None
        raise
