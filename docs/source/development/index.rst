Development
===========

This chapter is for people changing Blockinator itself: the Python package
under ``src/``, the Lambdas and Terraform under ``terraform/``, the tests,
or these pages.

Use whatever editor you like. An IDE with Python support, such as
`PyCharm <https://www.jetbrains.com/pycharm/>`_, is convenient but not
required.


Clone and install
-----------------

You need Python 3.13 or later (but not Python 4). Terraform **1.16.0 or
later** (but not 2.x) is required only if you will plan or apply the
infrastructure.

::

    git clone --quiet https://github.com/NASA-PDS/blockinator
    cd blockinator
    python3 -m venv .venv
    . .venv/bin/activate
    pip install --editable '.[dev]'

``pds-blockinator`` then runs from the tree under ``src/``. Edits are
picked up without reinstalling.

Install the pre-commit hooks so formatting, PEP 8, type hints, and secrets
checks run before a commit leaves your machine::

    pre-commit install
    pre-commit install -t pre-push
    pre-commit install -t prepare-commit-msg
    pre-commit install -t commit-msg

The ``dev`` extra already includes ``pre-commit``, ``tox``, Sphinx, pytest,
mypy, flake8, and ``detect-secrets``.


Layout
------

+-------------------------------+--------------------------------------------+
| Path                          | What lives there                           |
+===============================+============================================+
| ``src/pds/blockinator/``      | CLI, DynamoDB/SQS client, CIDR helpers     |
+-------------------------------+--------------------------------------------+
| ``terraform/``                | Platform stage: table, queue, Lambdas,     |
|                               | SSM parameters (engineers, run as needed)  |
+-------------------------------+--------------------------------------------+
| ``terraform/admin/``          | Admin stage: IAM roles/policies and WAF    |
|                               | IP sets (system administrators, run once)  |
+-------------------------------+--------------------------------------------+
| ``terraform/lambda/``         | Updater, sweeper, and audit function code  |
+-------------------------------+--------------------------------------------+
| ``tests/pds/blockinator/``    | Unit tests for the Python package          |
+-------------------------------+--------------------------------------------+
| ``docs/source/``              | These Sphinx pages                         |
+-------------------------------+--------------------------------------------+


Tests and lint
--------------

A full run — unit tests, coverage, lint, and this documentation — is::

    tox

That uses the ``py313``, ``docs``, and ``lint`` environments from
``tox.ini``. Useful subsets::

    tox -e py313          # pytest + coverage
    tox -e docs           # sphinx-build
    tox -e lint           # pre-commit --all
    pytest                # tests only, against the editable install

``lint`` is what CI's ``pre-commit`` job runs: Black-compatible flake8,
docstrings, naming, and mypy on ``pds.*``.


Documentation
-------------

Pages are reStructuredText under ``docs/source``, built with Sphinx.
Either of these writes HTML to ``docs/build/``::

    tox -e docs
    sphinx-build -b html docs/source docs/build

Open ``docs/build/index.html``. The published site is
https://nasa-pds.github.io/blockinator.


Secrets detection
-----------------

Every push and pull request to ``main`` runs the ``secrets-detection``
workflow. Locally, ``scripts/detect_secrets_baseline.sh`` is the single
source of scan arguments (the same flags CI uses). Repo-specific exclude
patterns go in ``.detect-secrets-ignore``, one regex per line.

If the workflow fails, there are two usual causes.

Unaudited findings in ``.secrets.baseline``
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The baseline has detections that have not been classified yet::

    scripts/detect_secrets_baseline.sh audit

Mark each finding as a real secret (``y``) or a false positive (``n``).
Commit the updated ``.secrets.baseline``.

New secrets not in the baseline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A new file or edit looks like a credential::

    scripts/detect_secrets_baseline.sh scan
    scripts/detect_secrets_baseline.sh audit

If it is a real secret, remove it, rotate the credential, and re-push. If
it is a false positive, mark it during audit and commit the baseline.

Routine re-scan
~~~~~~~~~~~~~~~

::

    scripts/detect_secrets_baseline.sh scan
    scripts/detect_secrets_baseline.sh audit
    git add .secrets.baseline

On a fresh clone, create the first baseline the same way, then
``git add .secrets.baseline``.


Continuous integration
----------------------

Two Roundup workflows ship with the repository:

* **unstable** (``.github/workflows/unstable-cicd.yaml``) — any push to
  ``main``. Publishes a snapshot to Test PyPI and refreshes GitHub Pages.
  Until there is a formal release, that snapshot is ``v0.0.0-SNAPSHOT``.
* **stable** (``.github/workflows/stable-cicd.yaml``) — push of a branch
  named ``release/<version>``. That is the official package and docs
  release.

A separate ``terraform_cicd.yaml`` workflow formats and validates the
Terraform root modules (the platform stage in ``terraform/`` and the
admin stage in ``terraform/admin/``). Plan/apply in that file stay
commented until the venue OIDC role is wired up.

There is also branch CI, CodeQL, and the secrets workflow above.


Publication
-----------

Prefer the stable Roundup workflow. For a manual build::

    pip install build
    python -m build .

Then attach ``dist/*`` to a GitHub release, or upload with Twine (needs
``$HOME/.pypirc``)::

    pip install twine
    twine upload dist/*                          # PyPI
    twine upload --repository testpypi dist/*    # Test PyPI


Contribute
----------

Please read the NASA-PDS `Contributing guidelines`_ and `Code of Conduct`_
before opening a pull request. Bug reports and feature requests go to
GitHub Issues; see :doc:`../support/contribute`.

.. _Contributing guidelines: https://github.com/NASA-PDS/.github/blob/main/CONTRIBUTING.md
.. _Code of Conduct: https://github.com/NASA-PDS/.github/blob/main/CODE_OF_CONDUCT.md
