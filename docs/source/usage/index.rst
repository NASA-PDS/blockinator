Usage
=====

``pds-blockinator`` adds, lists, and removes IP / CIDR blocks. It writes
DynamoDB and enqueues SQS only. Propagation to CloudFront is typically under
two minutes (FIFO invoke plus IP set update). The default time-to-live is
**12 hours**.

Confirm the tool is on your ``PATH``::

    pds-blockinator --help


Commands
--------

All commands share these optional flags:

``--profile PROFILE``
    AWS named profile (overrides ``AWS_PROFILE``).

Successful ``add`` and ``remove`` print the DynamoDB item as JSON.
``list`` prints a JSON array.


add
~~~

Block an IPv4 or IPv6 address or CIDR. ``--reason`` is required::

    pds-blockinator add 203.0.113.10 --reason "someone is scraping our images"
    pds-blockinator add 198.51.100.0/24 --reason "abusive subnet" --ttl 6h
    pds-blockinator add 203.0.113.99 --reason "persistent abuse" --no-expiry
    pds-blockinator add 2001:db8::1 --reason "ipv6 scraper" --ttl 30m

Bare addresses become ``/32`` (IPv4) or ``/128`` (IPv6). Host bits in a
network address are masked off, so ``10.1.2.3/8`` is stored as
``10.0.0.0/8``.

TTL values
^^^^^^^^^^

+------------------+------------------------------------------+
| Form             | Meaning                                  |
+==================+==========================================+
| (omitted)        | 12 hours                                 |
+------------------+------------------------------------------+
| ``12h``, ``6h``  | hours                                    |
+------------------+------------------------------------------+
| ``30m``          | minutes                                  |
+------------------+------------------------------------------+
| ``120s``         | seconds                                  |
+------------------+------------------------------------------+
| ``2d``           | days                                     |
+------------------+------------------------------------------+
| ``3600``         | bare integer, seconds                    |
+------------------+------------------------------------------+
| ``0`` or ``none``| no expiry (same as ``--no-expiry``)      |
+------------------+------------------------------------------+

``--no-expiry`` ignores any ``--ttl`` and omits ``expires_at`` on the item.
The sweeper never removes those rows; an operator must ``remove`` them.

list
~~~~

Show entries. Default filter is ``ACTIVE``::

    pds-blockinator list
    pds-blockinator list --status EXPIRED
    pds-blockinator list --status ALL
    pds-blockinator --profile my-sso list

``--status`` is one of ``ACTIVE``, ``EXPIRED``, or ``ALL``.

remove
~~~~~~

Lift a block immediately. The CIDR is canonicalized the same way as
``add``, so ``pds-blockinator remove 203.0.113.10`` matches
``203.0.113.10/32``::

    pds-blockinator remove 203.0.113.10
    pds-blockinator remove 203.0.113.10 --reason "false positive"

If the CIDR is not in the table, the CLI still enqueues a WAF REMOVE (so a
stale IP set entry can be cleared) and prints a tombstone item.


Verify a block against a live site
----------------------------------

First confirm you can reach the site over IPv4 and IPv6::

    curl --ipv4 --silent --show-error --dump-header - \
        --output /tmp/body.txt https://pds-sit.mcp.nasa.gov/
    curl --ipv6 --silent --show-error --dump-header - \
        --output /tmp/body.txt https://pds-sit.mcp.nasa.gov/

Both should return HTTP 200. Then block your own public IPv4 address for a
short window::

    my_ip=$(curl -4 -sS https://checkip.amazonaws.com)
    echo "$my_ip"
    pds-blockinator add "$my_ip" --reason "synthetic WAF test" --ttl 10m
    pds-blockinator list

Wait a couple of minutes for CloudFront / WAF to pick up the IP set change.
Repeat the ``curl`` commands: you should see HTTP 403, and ``/tmp/body.txt``
should contain the Help Desk message.

When you are done testing, either wait for the 10-minute TTL or run::

    pds-blockinator remove "$my_ip"


Logs
----

Updater Lambda (WAF writes), substituting the venue::

    aws logs tail /aws/lambda/pdc-cds-dev-pds-ip-blocklist-updater \
        --since 30m --region us-west-2

Audit events (add / remove / expire) go to the log group published as SSM
``audit-log-group``, typically
``/aws/lambda/<venue>-pds-ip-blocklist-audit``.


Exit codes
----------

* ``0`` — success
* ``2`` — usage or validation error (empty reason, invalid CIDR or TTL,
  unresolved table/queue)
* ``1`` — unexpected AWS or runtime failure


Automated producers
-------------------

Alarms or other automation must **not** call ``UpdateIPSet``. They write the
same DynamoDB table and FIFO queue the CLI uses. See
:doc:`../theory/index` for the item shape and SQS message body.
