Theory of Operation
===================

Blockinator is a **WAF proxy**: operators and automation never update the Web
ACL or IP sets directly. They mutate a source-of-truth table and a
single-group FIFO queue. One Lambda applies those mutations to CloudFront
WAF IP sets.

That split is the point. WAF ``UpdateIPSet`` is a read-modify-write against
a lock token; two concurrent writers will collide. Putting a single writer
behind a FIFO queue keeps order, retries cleanly, and lets the operator IAM
policy omit ``wafv2:*`` entirely.


Data path
---------

::

    operator or automation
            |
            |  put/update item          send message (group "ipset")
            +--------------> DynamoDB  +------------------> SQS FIFO
            |              (policies)                       |
            |                   |                           |
            |                   | stream                    | event source
            |                   v                           v
            |              audit Lambda              updater Lambda
            |              (CloudWatch)              (only WAF writer)
            |                                               |
            |                                               v
            |                                    WAFv2 IP sets (IPv4, IPv6)
            |                                    CLOUDFRONT scope, us-east-1
            |                                               |
            |                                               v
            |                                    existing CloudFront Web ACL
            |                                    (attached once by WAF owners)
            |
            +---- sweeper (every minute): ACTIVE + expires_at <= now
                  → status EXPIRED → enqueue REMOVE


Components
----------

DynamoDB table
~~~~~~~~~~~~~~

The table ``<venue>-pds-ip-blocklist-policies`` is the audit-friendly source
of truth. Partition key is the **canonical CIDR** (string). A global
secondary index on ``status`` + ``expires_at`` lets the sweeper find rows
whose TTL has passed.

Typical item attributes:

+------------------+--------------------------------------------------+
| Attribute        | Role                                             |
+==================+==================================================+
| ``cidr``         | Canonical CIDR (primary key)                     |
+------------------+--------------------------------------------------+
| ``action``       | ``BLOCK`` (``ALLOW`` is reserved for later work) |
+------------------+--------------------------------------------------+
| ``reason``       | Human-readable why                               |
+------------------+--------------------------------------------------+
| ``added_by``     | IAM principal ARN (or automation id)             |
+------------------+--------------------------------------------------+
| ``added_at``     | ISO-8601 UTC                                     |
+------------------+--------------------------------------------------+
| ``expires_at``   | Unix epoch seconds; omitted if no expiry         |
+------------------+--------------------------------------------------+
| ``source``       | ``MANUAL`` or ``AUTOMATED``                      |
+------------------+--------------------------------------------------+
| ``status``       | ``ACTIVE`` or ``EXPIRED``                        |
+------------------+--------------------------------------------------+
| ``address_family`` | ``IPV4`` or ``IPV6``                           |
+------------------+--------------------------------------------------+
| ``removed_at``   | Set when expired or explicitly removed           |
+------------------+--------------------------------------------------+

``add`` is a ``PutItem``: blocking the same CIDR again replaces the row
(new reason, new TTL, new ``added_by``). ``remove`` sets ``status`` to
``EXPIRED`` when the key exists; it still enqueues REMOVE if it does not,
so a leftover IP set entry can be cleared.

The table stream is ``NEW_AND_OLD_IMAGES`` so the audit Lambda can tell
inserts from expiry updates.

SQS FIFO mutation bus
~~~~~~~~~~~~~~~~~~~~~

Queue ``<venue>-pds-ip-blocklist-mutations.fifo`` carries the WAF work.
Every producer uses ``MessageGroupId`` ``ipset``, so messages are totally
ordered. Content-based deduplication is on; producers do not set a
deduplication id.

Message body::

    {"op": "ADD", "cidr": "203.0.113.10/32", "request_id": "<uuid>"}

``op`` is ``ADD`` or ``REMOVE``. The CIDR must already be canonical.

A dead-letter FIFO queue takes messages that fail five receives. Visibility
timeout is 120 seconds (twice the updater's 60-second timeout) so an
in-flight invoke is not retried underneath itself.

Updater Lambda
~~~~~~~~~~~~~~

This is the **only** identity with ``wafv2:UpdateIPSet`` (and
``wafv2:GetIPSet``) on the two blocklist IP sets. Reserved concurrency is
**1**, so two batches cannot race on the WAF lock token.

It is invoked from the FIFO queue with batch size 10 (the FIFO maximum).
It collapses a batch into per-family ADD and REMOVE sets (a later REMOVE
cancels an earlier ADD of the same CIDR in that batch, and vice versa),
then for each IP set that has work:

1. ``GetIPSet`` → current addresses + lock token
2. union ADDs, difference REMOVEs
3. ``UpdateIPSet`` with the full ``Addresses`` list

Delta APIs (``AddressesToAdd`` / ``AddressesToDelete``) are not used:
the Lambda runtime's botocore still requires the complete list. On
``WAFOptimisticLockException`` it retries with backoff.

Partial batch failure is reported so SQS retries only the messages that
did not apply.

Sweeper Lambda
~~~~~~~~~~~~~~

EventBridge runs the sweeper every minute. It queries
``status = ACTIVE AND expires_at <= now``, marks each row ``EXPIRED``,
and enqueues ``REMOVE``. Persistent rows (no ``expires_at``) never match
that query.

Audit Lambda
~~~~~~~~~~~~

The DynamoDB stream drives a small logger. Each record becomes one JSON
line classified as ``add``, ``remove``, ``expire``, or ``update``, with
CIDR, reason, operator, and source. Retention defaults to 90 days.

WAF IP sets and the Web ACL
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Terraform creates two empty IP sets in **us-east-1** with scope
``CLOUDFRONT``:

* ``<venue>-pds-ip-blocklist-ipv4``
* ``<venue>-pds-ip-blocklist-ipv6``

Everything else (table, queue, Lambdas) lives in the venue region, usually
``us-west-2``. The updater talks to WAFv2 in ``us-east-1`` regardless.

Attaching those sets to the existing Web ACL is a **one-time WAF-owner**
action. Terraform does not edit the ACL; CloudFront already consumes an
external ``waf_arn``. Rules should Block with a custom 403 body pointing
at the PDS Help Desk, and should sit above any future allowlist rule.


CIDR canonicalization
---------------------

All writers go through the same rules (Python ``ipaddress``):

* ``203.0.113.10`` → ``203.0.113.10/32``
* ``2001:db8::1`` → ``2001:db8::1/128``
* ``10.1.2.3/8`` → ``10.0.0.0/8`` (host bits masked)

The updater normalizes again when it parses SQS bodies, so a sloppy
producer still lands on the same IP set entry. Invalid values never reach
WAF; the CLI exits 2, and the updater reports the message as a batch
failure.


IAM
---

Least privilege is intentional:

* **Operator policy** (humans and automation running ``pds-blockinator``):
  DynamoDB write/scan, SQS ``SendMessage``, SSM ``GetParameter``. No
  ``wafv2:*``.
* **Updater role**: SQS consume, CloudWatch logs, ``GetIPSet`` /
  ``UpdateIPSet`` on the two IP sets only.
* **Sweeper role**: DynamoDB query/update (including the expiry GSI), SQS
  ``SendMessage``.
* **Audit role**: DynamoDB stream read and its own log group.

Operators therefore cannot widen or empty the IP sets except by going
through this pipeline.


SSM discovery
-------------

After apply, the stack publishes parameters under
``/pds/cds-infra/ip-blocklist/`` (table name, queue URL, IP set ARNs,
audit log group, operator policy ARN). The CLI uses that prefix when
``--table`` / ``--queue`` and the matching environment variables are
unset, so operators do not have to copy resource names around.


Automated producers
-------------------

Future auto-block (for example from rate alarms) should look like the CLI:

1. ``PutItem`` an ``ACTIVE`` / ``BLOCK`` row with ``source`` ``AUTOMATED``
   and ``added_by`` such as ``cloudwatch-alarm:<name>``.
2. ``SendMessage`` with ``MessageGroupId`` ``ipset`` and an ``ADD`` body.

Do not call ``UpdateIPSet`` from those producers. CloudFront access logs
today land in S3 via Logs Delivery, not a CloudWatch log group; metric
filters for auto-block need a Logs destination and will not work against
the S3 delivery as-is.


What operators see
------------------

Once the IP sets are on the Web ACL, a listed address is denied at
CloudFront with HTTP 403 and the Help Desk message. There is no
application-level change on the origin. Clearing a block is the reverse:
DynamoDB ``EXPIRED``, SQS ``REMOVE``, updater deletes the CIDR from the
matching IP set, CloudFront stops matching within a couple of minutes.
