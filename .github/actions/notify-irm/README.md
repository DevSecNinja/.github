# notify-irm

POST an alert state (`alerting`/`ok`) to a Grafana IRM Custom webhook
integration so a homelab IRM service can page on CI failure and
auto-resolve once the workflow goes green again.

## Behaviour

- Sends `state=alerting` when any prior job failed or was cancelled.
- Sends `state=ok` (with the same `alert_uid`) on a full green run so the
  open incident auto-resolves.
- Silently skips when `webhook-url` is empty, so the workflow remains
  usable on forks and during initial bring-up.
- `alert_uid` is keyed on `gha-<repo>-<workflow>-<branch>` (no SHA), so
  re-runs and follow-up commits collapse into the same alert group, and a
  green run on a later commit resolves the incident raised by an earlier
  failed commit.

## Inputs

| Name                 | Required | Default | Description                                                                                                |
| -------------------- | :------: | ------- | ---------------------------------------------------------------------------------------------------------- |
| `webhook-url`        |   yes    | —       | Grafana IRM Custom webhook URL. Empty value disables the step.                                             |
| `job-failed`         |   yes    | —       | `'true'` when any prior job failed/was cancelled, `'false'` otherwise.                                     |
| `service`            |    no    | `ci`    | Logical service tag for IRM routing/labelling.                                                             |
| `resolve-on-success` |    no    | `true`  | When `true`, a green run posts `state=ok` to auto-resolve. Set `false` for unique-uid workflows (e.g. tags). |

## Usage

```yaml
notify-irm:
  name: Notify Grafana IRM
  needs: [lint, test]
  if: ${{ always() && github.ref == 'refs/heads/main' && github.event_name == 'push' }}
  runs-on: ubuntu-24.04
  permissions:
    contents: read
  steps:
    - name: Notify Grafana IRM
      uses: DevSecNinja/.github/.github/actions/notify-irm@<sha> # main
      with:
        webhook-url: ${{ secrets.GRAFANA_IRM_WEBHOOK_URL }}
        # `needs.*.result` is system-controlled, safe to interpolate.
        job-failed: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
```

For tag-push workflows where every run has a unique `alert_uid`, set
`resolve-on-success: "false"` and gate with `if: ${{ always() }}` instead.
