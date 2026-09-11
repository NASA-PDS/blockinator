# Blockinator

Welcome! The Blockinator is a tool for the Planetary Data System that enables operators to both dynamically and automatically update lists of IP addresses and CIDR blocks that should be prevented from reaching their PDS-curated destinations by dynamically updating lists of blocked IPs. The best part about this: operators never need firewall console access.

Instead, we have a "WAF Proxy".

The Blockinator's WAF proxy operates by manipulating a [Web Application Firewall](https://aws.amazon.com/waf/) (WAF) of a [CloudFront](https://aws.amazon.com/cloudfront/) distribution without requiring access to the WAF or the [Amazon Web Services](https://aws.amazon.com/) console. When bot activity or abusive behavior is found, an operator and run the Blockinator command to block a single IP or an entire CIDR block of addresses while listing a reason and a time limit. Those matching addresses receive an HTTP 403 (Forbidden) error code and a message:

> Unusual traffic has been detected that looks like automated/bot activity. If you require access to this data, please contact the PDS Help Desk at pds-operator@jpl.nasa.gov.

After the time limit passes, the block is automatically removed. Operators can also list the current blocks and preemptively remove blocks.

Please visit our website at: https://nasa-pds.github.io/blockinator.  It has useful information for developers and end-users.


## Prerequisites

This package provides both an installable-anywhere Python tool plus the supporting AWS infrastructure. Installation of the tool can be done by anyone anywhere so long as the following requirements are met:

- Python 3.13 or later, but less than Python 4
- AWS access to the roles needed (typically the PDS "Power User" role)

The cloud infrastructure only needs to be set up one time, and requires the following:

- Terraform 1.16.0 or later, but less than Terraform 2.0.0
- AWS access to the roles needed (typical the PDS "Project Admin" role)


## User Quickstart

Install and run with:

    pip install pds-blockinator
    pds-blockinator --help

The `pds-blockinator` console script manages the operator IP/CIDR blocklist

## Usage Examples

Here are some examples of what PDS Operators (or their coding companions) will be executing:

```bash
pds-blockinator add 203.0.113.10 --reason "someone is scraping our images"
pds-blockinator add 198.51.100.0/24 --reason "abusive subnet" --ttl 6h
pds-blockinator add 203.0.113.99 --reason "just out of spite, I think my ex lives there" --no-expiry
pds-blockinator --profile my-sso list
pds-blockinator remove 203.0.113.10
```
To test it out, first attempt to visit the site unblocked (using separate IPv4 and IPv6 calls):

    curl --ipv4 --silent --show-error --dump-header - --output /tmp/body.txt https://pds-sit.mcp.nasa.gov/
    curl --ipv6 --silent --show-error --dump-header - --output /tmp/body.txt https://pds-sit.mcp.nasa.gov/

Ensure you receive HTTP 200 (OK) for both. Next, block yourself:

    my_ip=`curl -4 -sS https://checkip.amazonaws.com`
    echo "$my_ip"
    pds-blockinator add "$my_ip" --reason "synthetic WAF test" --ttl 10m
    pds-blockinator list

Wait a couple minutes for the changes to propagate. Then try the `curl` commands again and ensure you get HTTP 403 (Forbidden). The payload body `/tmp/body.txt` should also contain the reason why.

You can also get the logs:

    aws logs tail /aws/lambda/pdc-cds-dev-pds-ip-blocklist-updater --since 30m --region us-west-2

Substitute the venue as needed.

The CLI writes DynamoDB and enqueues SQS only. It has no `wafv2:*` permissions. Propagation target is under two minutes (FIFO invoke + IPSet update). Default TTL is **12 hours**.

Resolve table/queue via:

1. `--table` / `--queue`
2. `PDS_BLOCKLIST_TABLE` / `PDS_BLOCKLIST_QUEUE_URL`
3. SSM under `--ssm-prefix` (default `/pds/cds-infra/ip-blocklist`)


## Code of Conduct

All users and developers of the NASA-PDS software are expected to abide by our [Code of Conduct](https://github.com/NASA-PDS/.github/blob/main/CODE_OF_CONDUCT.md). Please read this to ensure you understand the expectations of our community.


## Development

To develop this project, use your favorite text editor, or an integrated development environment with Python support, such as [PyCharm](https://www.jetbrains.com/pycharm/).


### Secrets Detection

The `secrets-detection` CI workflow runs on every push and pull request to `main`. It uses [`detect-secrets`](https://github.com/Yelp/detect-secrets) to catch accidental credential commits.


#### If the workflow fails

There are two failure modes:

**1. Unaudited secrets in `.secrets.baseline`**

The baseline contains detected secrets that haven't been reviewed yet. Fix locally:

```bash
pip install detect-secrets~=1.5.0
scripts/detect_secrets_baseline.sh audit
```

Step through each finding and mark it as a real secret (`y`) or a false positive (`n`). Commit the updated `.secrets.baseline`.

**2. New secrets detected (not in baseline)**

A newly added file or change contains something that looks like a secret. Fix locally:

```bash
# Regenerate the baseline to capture current state
scripts/detect_secrets_baseline.sh scan

# Audit any new findings
scripts/detect_secrets_baseline.sh audit
```

If the detected value is a real secret, remove it from the code, rotate the credential, and re-push. If it's a false positive, mark it as such during audit, then commit the updated `.secrets.baseline`.


### Updating the baseline (routine re-scan)

```bash
pip install detect-secrets~=1.5.0
./scripts/detect_secrets_baseline.sh scan
./scripts/detect_secrets_baseline.sh audit
git add .secrets.baseline
git commit --message "Update secrets baseline"
```

The script in `scripts/detect_secrets_baseline.sh` is the single source of truth for scan arguments (exclude patterns, etc.) used by both local runs and CI.


### Contributing

For information on how to contribute to NASA-PDS codebases please take a look at our [Contributing guidelines](https://github.com/NASA-PDS/.github/blob/main/CONTRIBUTING.md).


### Installation

Clone the repository and install the pre-commit hooks:

    git clone --quiet https://github.com/NASA-PDS/blockinator
    cd blockinator
    pre-commit install
    pre-commit install -t pre-push
    pre-commit install -t prepare-commit-msg
    pre-commit install -t commit-msg

These hooks then will check for any future commits that might contain secrets. They also check code formatting, PEP8 compliance, type hints, etc.

Next, create and activate your Python virtual environment, the install the package from source in development mode:

    python3 -m venv .venv
    . .venv/bin/activate
    pip install --editable '.[dev]'

Make a baseline for any secrets (email addresses, passwords, API keys, etc.) in the repository:

    scripts/detect_secrets_baseline.sh scan

Review and classify each detected secret (mark as `is_secret: true/false`):

    scripts/detect_secrets_baseline.sh audit

Commit the baseline:

    git add .secrets.baseline

To exclude additional files specific to this repo from scanning, add regex patterns (one per line) to `.detect-secrets-ignore`. Global exclusions (`.git`, `venv`, `dist`, etc.) are already handled by the script.


### Tests

A complete "build" including test execution, linting (`mypy`, `black`, `flake8`, etc.), and documentation build is executed via:

    tox


## Publication

NASA PDS packages can publish automatically using the [Roundup Action](https://github.com/NASA-PDS/roundup-action), which leverages GitHub Actions to perform automated continuous integration and continuous delivery. A default workflow that includes the Roundup is provided in the `.github/workflows/unstable-cicd.yaml` file. (Unstable here means an interim release.)


### Manual Publication

Create the package:

    pip install build
    python -m build .

Publish it as a Github release.

Publish on PyPI (you need a PyPI account and configure `$HOME/.pypirc`):

    pip install twine
    twine upload dist/*

Or publish on the Test PyPI (you need a Test PyPI account and configure `$HOME/.pypirc`):

    pip install twine
    twine upload --repository testpypi dist/*


## CI/CD

The template repository comes with our two "standard" CI/CD workflows, `stable-cicd` and `unstable-cicd`. The unstable build runs on any push to `main` (± ignoring changes to specific files) and the stable build runs on push of a release branch of the form `release/<release version>`. Both of these make use of our GitHub actions build step, [Roundup](https://github.com/NASA-PDS/roundup-action). The `unstable-cicd` will generate (and constantly update) a snapshot or "in-development" release. If you haven't done a formal software release you will end up with a `v0.0.0-SNAPSHOT` release (see NASA-PDS/roundup-action#56 for specifics).
