# -*- coding: utf-8 -*-
"""Tests for BlocklistClient and the pds-blockinator console script."""
from unittest.mock import MagicMock

import pytest
from pds.blockinator.cli import _build_parser
from pds.blockinator.cli import main
from pds.blockinator.client import BlocklistClient


def _client():
    table = MagicMock()
    sqs = MagicMock()
    sts = MagicMock()
    sts.get_caller_identity.return_value = {"Arn": "arn:aws:iam::123:user/operator"}
    dynamodb = MagicMock()
    dynamodb.Table.return_value = table
    client = BlocklistClient(
        "test-table",
        "https://sqs.us-west-2.amazonaws.com/123/queue.fifo",
        dynamodb_resource=dynamodb,
        sqs_client=sqs,
        sts_client=sts,
    )
    return client, table, sqs


def test_add_writes_item_and_enqueues():
    """add() stores an ACTIVE BLOCK row and sends ADD to SQS."""
    client, table, sqs = _client()
    item = client.add("203.0.113.10", "scraping /data/store/img", ttl="2h")
    table.put_item.assert_called_once()
    written = table.put_item.call_args.kwargs["Item"]
    assert written["cidr"] == "203.0.113.10/32"
    assert written["action"] == "BLOCK"
    assert written["status"] == "ACTIVE"
    assert written["source"] == "MANUAL"
    assert written["reason"] == "scraping /data/store/img"
    assert written["added_by"] == "arn:aws:iam::123:user/operator"
    assert "expires_at" in written
    assert item["cidr"] == written["cidr"]
    sqs.send_message.assert_called_once()
    body = sqs.send_message.call_args.kwargs["MessageBody"]
    assert '"op": "ADD"' in body
    assert "203.0.113.10/32" in body
    assert sqs.send_message.call_args.kwargs["MessageGroupId"] == "ipset"


def test_add_requires_reason():
    """add() refuses an empty reason."""
    client, _, _ = _client()
    with pytest.raises(ValueError, match="reason"):
        client.add("203.0.113.10", "  ")


def test_add_no_expiry_omits_expires_at():
    """Persistent blocks do not set expires_at."""
    client, table, _ = _client()
    client.add("10.0.0.0/8", "lab subnet", no_expiry=True)
    written = table.put_item.call_args.kwargs["Item"]
    assert "expires_at" not in written


def test_remove_marks_expired_and_enqueues():
    """remove() updates status and sends REMOVE to SQS."""
    client, table, sqs = _client()
    table.update_item.return_value = {
        "Attributes": {"cidr": "203.0.113.10/32", "status": "EXPIRED"},
    }
    item = client.remove("203.0.113.10")
    table.update_item.assert_called_once()
    assert item["status"] == "EXPIRED"
    assert '"op": "REMOVE"' in sqs.send_message.call_args.kwargs["MessageBody"]


def test_list_filters_active():
    """list_entries() scans with a status filter."""
    client, table, _ = _client()
    table.scan.return_value = {"Items": [{"cidr": "203.0.113.10/32"}]}
    items = client.list_entries()
    assert items[0]["cidr"] == "203.0.113.10/32"
    assert table.scan.call_args.kwargs["ExpressionAttributeValues"][":status"] == "ACTIVE"


def test_cli_add(monkeypatch, capsys):
    """The add subcommand prints the written item as JSON."""
    fake = MagicMock()
    fake.add.return_value = {"cidr": "203.0.113.10/32", "status": "ACTIVE"}
    monkeypatch.setattr(
        "pds.blockinator.cli.BlocklistClient.from_environment",
        lambda **_kwargs: fake,
    )
    rc = main(["add", "203.0.113.10", "--reason", "bot"])
    assert rc == 0
    fake.add.assert_called_once()
    out = capsys.readouterr().out
    assert "203.0.113.10/32" in out


def test_cli_invalid_cidr_is_exit_two(monkeypatch, capsys):
    """ValueError from the client becomes exit code 2."""
    fake = MagicMock()
    fake.add.side_effect = ValueError("Invalid IP or CIDR: nope")
    monkeypatch.setattr(
        "pds.blockinator.cli.BlocklistClient.from_environment",
        lambda **_kwargs: fake,
    )
    rc = main(["add", "nope", "--reason", "x"])
    assert rc == 2
    assert "Invalid IP or CIDR" in capsys.readouterr().err


def test_cli_help_documents_profile():
    """Top-level help explains --profile PROFILE."""
    help_text = _build_parser().format_help()
    assert "--profile PROFILE" in help_text
    assert "AWS named profile" in help_text


def test_cli_passes_profile(monkeypatch):
    """--profile is forwarded to BlocklistClient.from_environment."""
    captured = {}

    def fake_from_environment(**kwargs):
        captured.update(kwargs)
        fake = MagicMock()
        fake.list_entries.return_value = []
        return fake

    monkeypatch.setattr(
        "pds.blockinator.cli.BlocklistClient.from_environment",
        fake_from_environment,
    )
    rc = main(["--profile", "ops", "list"])
    assert rc == 0
    assert captured["profile"] == "ops"


def test_from_environment_uses_named_profile(monkeypatch):
    """from_environment builds boto3 clients from the given profile."""
    session = MagicMock()
    dynamodb = MagicMock()
    dynamodb.Table.return_value = MagicMock()
    session.resource.return_value = dynamodb
    session.client.return_value = MagicMock()
    session_cls = MagicMock(return_value=session)
    monkeypatch.setattr(
        "pds.blockinator.client.boto3.session.Session",
        session_cls,
    )
    monkeypatch.setenv("PDS_BLOCKLIST_TABLE", "test-table")
    monkeypatch.setenv("PDS_BLOCKLIST_QUEUE_URL", "https://sqs.example/queue.fifo")
    BlocklistClient.from_environment(profile="Project-Power-User")
    session_cls.assert_called_once_with(profile_name="Project-Power-User")
    session.resource.assert_called_once_with("dynamodb")
    session.client.assert_any_call("sqs")
    session.client.assert_any_call("sts")
