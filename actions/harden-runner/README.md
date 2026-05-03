# `harden-runner` composite action

Apply [StepSecurity Harden-Runner](https://github.com/step-security/harden-runner)
runtime controls to the current GitHub Actions job.

This repository wraps the upstream action in a composite action so callers can
use the organisation-owned `DevSecNinja/.github` action pin while still running
Harden-Runner inside the job that needs protection. A reusable workflow would
run on a separate runner and would not harden the caller's build, test, or
release steps.

The wrapper defaults to `egress-policy: audit` for a non-breaking rollout. Use
audit findings to create `allowed-endpoints`, then switch high-value jobs to
`egress-policy: block`.

## Inputs

| Name                          | Required | Default               | Description                                                                         |
| ----------------------------- | -------- | --------------------- | ----------------------------------------------------------------------------------- |
| `allowed-endpoints`           | no       | `""`                  | Allowed outbound endpoints when `egress-policy` is `block`.                         |
| `egress-policy`               | no       | `audit`               | Outbound traffic policy: `audit` or `block`.                                        |
| `token`                       | no       | `${{ github.token }}` | GitHub token used by Harden-Runner to avoid API rate limits.                        |
| `disable-telemetry`           | no       | `false`               | Disable telemetry to StepSecurity. Only supported when `egress-policy` is `block`.  |
| `disable-sudo-and-containers` | no       | `false`               | Disable sudo and container access for the runner account.                           |
| `disable-file-monitoring`     | no       | `false`               | Disable file monitoring.                                                            |
| `policy`                      | no       | `""`                  | Policy name to use from the policy store. Requires `id-token: write`.               |
| `use-policy-store`            | no       | `false`               | Fetch policy from the StepSecurity policy store.                                    |
| `api-key`                     | no       | `""`                  | StepSecurity API key for policy-store authentication. Store this in GitHub Secrets. |
| `deploy-on-self-hosted-vm`    | no       | `false`               | Deploy the agent directly on an ephemeral self-hosted Linux VM.                     |

## Caller responsibilities

- Add this action as early as possible in each job you want to monitor,
  typically immediately after checkout.
- Keep job permissions least-privilege. Add `id-token: write` only when using
  the `policy` input.
- Start with `egress-policy: audit`; move to `block` only after defining a
  reviewed `allowed-endpoints` list.
- Do not pass `api-key` as plaintext. Use `${{ secrets.STEPSECURITY_API_KEY }}`.

## Example — audit mode

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # v6.0.2
        with:
          persist-credentials: false

      - uses: DevSecNinja/.github/actions/harden-runner@<sha> # v1.2.0

      - run: npm test
```

## Example — block mode

```yaml
jobs:
  release:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@<sha> # v6.0.2
        with:
          persist-credentials: false

      - uses: DevSecNinja/.github/actions/harden-runner@<sha> # v1.2.0
        with:
          egress-policy: block
          allowed-endpoints: |
            api.github.com:443
            github.com:443
            objects.githubusercontent.com:443
          disable-sudo-and-containers: "true"

      - run: ./script/release.sh
```
