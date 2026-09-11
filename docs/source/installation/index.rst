Installation
============

Blockinator has two installable pieces:

1. The ``pds-blockinator`` command, which any operator can install locally.
2. The AWS infrastructure (DynamoDB, SQS, Lambdas, WAF IP sets), which is
   applied once per venue with Terraform.

Most readers only need the command-line tool. Infrastructure steps are for
the people who own the PDS CloudFront / WAF account.


Operator CLI
------------

This is the **operator** command-line tool. It runs on your computer and
requires no AWS access (aside from AWS credentials).


Requirements
~~~~~~~~~~~~

* Python 3.13 or later (but not Python 4).
* AWS credentials that can assume the operator role — typically the PDS
  **Power User** role, with the Blockinator operator IAM policy attached.
  That policy can write the blocklist table and mutation queue and read SSM;
  it cannot call ``wafv2:*``.


Install from PyPI
~~~~~~~~~~~~~~~~~

Create a virtual environment (recommended) and install the package::

    python3 -m venv $HOME/.virtualenvs/pds-blockinator
    source $HOME/.virtualenvs/pds-blockinator/bin/activate
    pip install pds-blockinator
    pds-blockinator --help

If the package is not yet on PyPI, you can install from GitHub instead::

    pip install git+https://github.com/NASA-PDS/blockinator.git

or from source; see :doc:`../development/index`.

Upgrade later with ``pip install --upgrade pds-blockinator``.


AWS credentials
~~~~~~~~~~~~~~~

The CLI uses the standard boto3 credential chain. Pass a named profile with
``--profile``, or set ``AWS_PROFILE``. For example::

    pds-blockinator --profile my-sso list

Or set up `aws configure sso` or create `AWS_*` environment variables.

You do not need WAF or CloudFront console access. You do need permission to:

* ``dynamodb:PutItem`` / ``UpdateItem`` / ``Scan`` (and related) on the
  blocklist table
* ``sqs:SendMessage`` on the mutation queue
* ``ssm:GetParameter`` under the blocklist prefix (unless you pass
  ``--table`` and ``--queue`` yourself)

Terraform publishes a managed policy for this. Its ARN is in SSM at
``/pds/cds-infra/ip-blocklist/operator-policy-arn``. Attach that policy to
the IAM role operators assume.


Custom table and queue
~~~~~~~~~~~~~~~~~~~~~~

You almost never need to set the table and queue names yourself. However, for
development and testing, know that the CLI resolves the table and queue names
in this order:

1. ``--table`` / ``--queue`` on the command line
2. ``PDS_BLOCKLIST_TABLE`` / ``PDS_BLOCKLIST_QUEUE_URL`` in the environment
3. SSM parameters ``table-name`` and ``queue-url`` under ``--ssm-prefix``
   (or ``PDS_BLOCKLIST_SSM_PREFIX``). The default prefix is
   ``/pds/cds-infra/ip-blocklist``.

If none of those succeed, the command exits with a message telling you what
to set.


AWS infrastructure (once per venue)
-----------------------------------

.. important::

  Only PDS Platform Engineers at the Engineering Node need to set up the AWS
  infrastructure.

Apply this only if you are standing up or changing the Blockinator stack.
It requires Terraform **1.16.0 or later** (but not 2.x) and AWS access
typical of the PDS **Project Admin** role.

What Terraform creates
~~~~~~~~~~~~~~~~~~~~~~

+----------------------------------+------------------------------------------------------+
| Resource                         | Role                                                 |
+==================================+======================================================+
| DynamoDB table ``*-policies``    | Source of truth (who / when / reason / TTL)          |
+----------------------------------+------------------------------------------------------+
| SQS FIFO queue ``*-mutations``   | Serialized ADD / REMOVE bus                          |
+----------------------------------+------------------------------------------------------+
| Lambda ``*-updater``             | Sole caller of ``wafv2:UpdateIPSet``                 |
+----------------------------------+------------------------------------------------------+
| Lambda ``*-sweeper``             | Expires rows whose TTL has passed                    |
+----------------------------------+------------------------------------------------------+
| Lambda ``*-audit``               | Structured logs from the DynamoDB stream             |
+----------------------------------+------------------------------------------------------+
| WAFv2 IP sets (IPv4 and IPv6)    | CloudFront-scoped lists in ``us-east-1``             |
+----------------------------------+------------------------------------------------------+

Resource names are ``<venue>-pds-ip-blocklist-…``. For venue
``pdc-cds-dev`` that is ``pdc-cds-dev-pds-ip-blocklist-policies``, and so on.

This stack does **not** modify the CloudFront Web ACL. After apply, a WAF
owner must attach the two IP sets once (see below).

Apply
~~~~~

From the repository's ``terraform/`` directory::

    cp terraform.tfvars.example terraform.tfvars
    # Edit terraform.tfvars: set venue (e.g. pdc-cds-dev), region, profile,
    # and permissions_boundary_arn as required by the account.

    terraform init -backend-config=backend-configs/dev.hcl
    terraform plan
    terraform apply

Use ``backend-configs/test.hcl`` or ``backend-configs/prod.hcl`` for those
venues. If you already initialized against another venue, add
``-reconfigure`` so Terraform does not try to migrate state between
buckets.

Copy ``backend-configs/<venue>.hcl.example`` if you need a new backend
file. Each file sets the S3 ``bucket``, ``key``, and ``region`` for
remote state.

Outputs are also written under SSM prefix
``/pds/cds-infra/ip-blocklist/``:

* ``table-name``
* ``queue-url``
* ``ipv4-ipset-arn``
* ``ipv6-ipset-arn``
* ``audit-log-group``
* ``operator-policy-arn``

One-time Web ACL attach (WAF owners only)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Attach **both** IP sets to the existing CloudFront Web ACL, **above** any
future allowlist rule, and without changing other rules.

1. Open the Web ACL (for example ``JPLOnlyWebACL``) in WAF & Shield.
2. Manage rules → Add rule → Custom rule.
3. Configure:

   * **Action:** Block
   * **Rule name:** ``blockinator-ipv4`` (then repeat as
     ``blockinator-ipv6``)
   * **If a request:** matches the statement
   * **Inspect:** originates from an IP address in
   * **IP set:** ``<venue>-pds-ip-blocklist-ipv4`` (or ``-ipv6``)
   * **IP address to use:** Source IP address
   * **Custom response:** enabled, status **403**, body:

     .. code-block:: text

         Unusual traffic has been detected that looks like automated/bot
         activity. If you require access to this data, please contact the
         PDS Help Desk at pds-operator@jpl.nasa.gov.

4. Add the rule. Repeat for IPv6.

IP set ARNs, if you need them::

    aws ssm get-parameter \
        --name /pds/cds-infra/ip-blocklist/ipv4-ipset-arn \
        --query Parameter.Value --output text
    aws ssm get-parameter \
        --name /pds/cds-infra/ip-blocklist/ipv6-ipset-arn \
        --query Parameter.Value --output text


Working on the code
-------------------

Operator install is enough to *run* ``pds-blockinator``. To clone the
repository, run tests, or change Terraform and Lambdas, see
:doc:`../development/index`.
