Installation
============

Blockinator has two installable pieces:

1. The ``pds-blockinator`` command, which any operator can install locally.
2. The AWS infrastructure (DynamoDB, SQS, Lambdas, WAF IP sets), applied
   with Terraform in **two stages**: an admin stage run once per venue by
   system administrators, and a platform stage run as needed by PDS
   platform engineers.

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


AWS infrastructure (two stages)
-------------------------------

.. important::

  Only PDS personnel at the Engineering Node need to set up the AWS
  infrastructure — and *which* personnel depends on the stage, below.

The Terraform is split into two independent stages with separate state,
based on the level of AWS access required. Both require Terraform
**1.16.0 or later** (but not 2.x).

+--------------+---------------------+-------------------------------+-----------------+
| Stage        | Directory           | Who runs it                   | When            |
+==============+=====================+===============================+=================+
| **Admin**    | ``terraform/admin/``| System administrators with    | Once per venue, |
|              |                     | elevated "super user" access  | first           |
|              |                     | (PDS **Project Admin** role)  |                 |
+--------------+---------------------+-------------------------------+-----------------+
| **Platform** | ``terraform/``      | Any PDS platform engineer     | As needed       |
|              |                     | (PDS **Power User** role)     |                 |
+--------------+---------------------+-------------------------------+-----------------+

The admin stage must be applied first: the platform stage looks up the
IAM roles, operator policy, and IP sets by name and fails with a clear
"not found" error if they do not exist yet. After the one-time admin
apply (plus the one-time Web ACL attach below), platform engineers never
need elevated access again.

Stage 1: Admin (system administrators, run once)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Creates the privileged resources:

+----------------------------------+------------------------------------------------------+
| Resource                         | Role                                                 |
+==================================+======================================================+
| IAM roles ``*-updater``,         | Lambda execution roles; only the updater role may    |
| ``*-sweeper``, ``*-audit``       | call ``wafv2:UpdateIPSet``                           |
+----------------------------------+------------------------------------------------------+
| IAM policy ``*-operator``        | Attach to operators who run ``pds-blockinator``      |
+----------------------------------+------------------------------------------------------+
| WAFv2 IP sets (IPv4 and IPv6)    | CloudFront-scoped lists in ``us-east-1``             |
+----------------------------------+------------------------------------------------------+

Deployment goes through Terragrunt in the ``cds-infra-deploy``
repository, which supplies the S3 backend, state key, and inputs::

    cd cds-infra-deploy/venues/dev/blockinator/admin   # or test/prod
    terragrunt init
    terragrunt plan
    terragrunt apply

The leaf's path yields state key ``blockinator/admin.tfstate``, which
**must differ** from the platform stage's
``blockinator/terraform.tfstate``. (To run plain Terraform instead, see
``terraform/admin/README.md`` in the repository for how to pass the
backend settings and state key via ``-backend-config``.) System
administrators also perform the one-time Web ACL attach described below.

Stage 2: Platform (platform engineers, run as needed)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Creates everything else:

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
| SSM parameters                   | Published discovery values for the CLI               |
+----------------------------------+------------------------------------------------------+

Resource names are ``<venue>-pds-ip-blocklist-…``. For venue
``pdc-cds-dev`` that is ``pdc-cds-dev-pds-ip-blocklist-policies``, and so on.

Deployment goes through Terragrunt in the ``cds-infra-deploy``
repository::

    cd cds-infra-deploy/venues/dev/blockinator/terraform   # or test/prod
    terragrunt init
    terragrunt plan
    terragrunt apply

To run plain Terraform instead (for example during development), work
from the repository's ``terraform/`` directory and pass the venue's
backend settings plus the state key by hand::

    cp terraform.tfvars.example terraform.tfvars
    # Edit terraform.tfvars
    terraform init \
        -backend-config=.../path/to/venue-backend.hcl \
        -backend-config='key=blockinator/terraform.tfstate'
    terraform plan
    terraform apply

Take the backend values (bucket, region, lock table) from
``cds-infra-deploy``. If you already initialized against another
backend, add ``-reconfigure`` so Terraform does not try to migrate state
between buckets.

If ``terraform plan`` fails with errors like *"no IAM role found matching
criteria"* or *"WAFv2 IPSet not found"*, the admin stage has not been
applied for this venue yet — ask a system administrator to run Stage 1
first.

Outputs are also written under SSM prefix ``/pds/cds-infra/ip-blocklist/``:

* ``table-name``
* ``queue-url``
* ``ipv4-ipset-arn``
* ``ipv6-ipset-arn``
* ``audit-log-group``
* ``operator-policy-arn``

Neither stage modifies the CloudFront Web ACL. After both stages apply, a
system administrator / WAF owner must attach the two IP sets once (see
below).


One-time Web ACL attach (system administrators / WAF owners only)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

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
