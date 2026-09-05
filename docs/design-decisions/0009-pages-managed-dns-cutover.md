# ADR 0009: Opt into safe Pages DNS cutover

## Status

Accepted

Supersedes the DNS-management decision in
[ADR 0008](0008-pages-custom-domain-registration.md) when a caller explicitly
opts in. ADR 0008 remains the default behavior.

## Context

Cloudflare Pages custom-domain registration and DNS routing are separate
operations. ADR 0008 deliberately stopped after registration because callers
may use another DNS provider or account. Some callers, however, own the
Cloudflare zone and want the same production pipeline to complete a controlled
cutover after deployment.

Wrangler supports Pages project creation and deployment, but it has no robust,
generic DNS-record management command suitable for collision detection and
fail-closed updates. Cloudflare's official REST API exposes the required zone and
DNS record operations.

## Decision

Keep DNS management disabled by default. A caller may opt in with
`cloudflare-manage-dns: true`, a lowercase `cloudflare-dns-zone`, and the
existing lowercase `cloudflare-custom-domain`. The custom domain must equal the
zone or end at a DNS-label boundary beneath it.

After a successful production deployment and idempotent Pages-domain
registration, the workflow:

1. Uses the configured account to resolve exactly one active matching zone.
2. Reads every page of records matching the exact custom-domain name.
3. Creates a TTL-auto CNAME to the Pages project's resolved `pages.dev`
   subdomain when no record exists.
4. Performs no write when one exact CNAME already has the desired target and
   proxy state.
5. Fails without mutation for duplicates, another record type, another target,
   another proxy state, ambiguous zones, or API errors.
6. Polls the Pages domain for a bounded period after DNS is managed. Remaining
   `initializing` or `pending` state produces a notice; failed or unknown states
   fail.

The existing API token is used directly with Cloudflare's official API. It needs
Account Cloudflare Pages Write, Zone Read, and DNS Edit permissions. Responses
are validated for HTTP status, Cloudflare's `success` and `errors` fields,
pagination, and expected result identity. Tokens and resource IDs are not
reported.

## Consequences

- Existing callers, previews, acceptance deployments, cleanup jobs, and GitHub
  Pages users are unchanged because DNS management defaults to `false`.
- A collision-safe target such as `net-worth-calculator-xn8.pages.dev` remains
  authoritative; the requested project name is never synthesized into a target.
- The workflow will not hijack or silently replace an existing hostname. A
  migration from an existing record requires an intentional manual change.
- Disabling the option does not delete records. Rollback is explicit: restore
  the prior service if needed, then remove a workflow-created CNAME through
  Cloudflare after traffic is safe.
