PDS Blockinator
===============

The Blockinator lets Planetary Data System operators block IP addresses and
CIDR ranges from CloudFront-fronted PDS sites **without** signing into the
AWS WAF or CloudFront consoles.

When bot traffic or other abuse shows up, an operator runs ``pds-blockinator``
with the address, a reason, and an optional time limit. Matching clients then
receive HTTP 403 (Forbidden) and this message:

.. code-block:: text

    Unusual traffic has been detected that looks like automated/bot activity.
    If you require access to this data, please contact the PDS Help Desk at
    pds-operator@jpl.nasa.gov.

After the time limit passes, the block is removed automatically. Operators can
also list current blocks and lift them early.

How it stays off the WAF console
--------------------------------

The command-line tool is a **WAF proxy**. It writes a DynamoDB table (who,
when, why, how long) and enqueues a mutation on a FIFO SQS queue. A
single-writer Lambda is the only identity allowed to call
``wafv2:UpdateIPSet``. Operators never need ``wafv2:*`` permissions.

Start here
----------

* :doc:`installation/index` — install the CLI, and set up the AWS
  infrastructure (a one-time admin stage, then an engineer-run platform
  stage).
* :doc:`usage/index` — add, list, and remove blocks, including a self-test
  against a live site.
* :doc:`theory/index` — how the table, queue, Lambdas, and WAF IP sets fit
  together.
* :doc:`development/index` — clone, test, document, and release the code.

.. toctree::
    :maxdepth: 2
    :caption: Contents

    installation/index
    usage/index
    theory/index
    development/index

.. toctree::
    :maxdepth: 1
    :caption: Support

    support/contribute
    support/contact
