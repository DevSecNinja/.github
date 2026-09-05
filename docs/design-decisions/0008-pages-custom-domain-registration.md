# ADR 0008: Register Pages domains without managing DNS

## Status

Accepted

## Context

Cloudflare Pages needs two independent changes before a custom hostname serves a
site: the hostname must be registered on the Pages project, and DNS must point
at the project's assigned `pages.dev` subdomain. A caller may own DNS in another
account or provider, so the central Pages workflow cannot safely assume zone
ownership or manage DNS records.

The requested Pages project name is also not a reliable DNS target. Cloudflare
may assign a collision-safe subdomain such as
`net-worth-calculator-xn8.pages.dev` to a project requested as
`net-worth-calculator`.

## Decision

Add one optional `cloudflare-custom-domain` input to the reusable Pages workflow.
It accepts a single lowercase FQDN and is valid only with an explicit Cloudflare
project name and production deployment. After the production deployment
succeeds, the workflow:

1. Uses the project name resolved by the existing detection job.
2. Queries the exact domain through the official Pages API.
3. Reuses domains in `initializing`, `pending`, or `active` state, or registers
   an absent domain with Pages Write credentials.
4. Fails on transport errors, unsuccessful API responses, mismatched data, or
   terminal/unexpected domain states.
5. Queries the Pages project and reports its actual `subdomain` as the required
   DNS CNAME target.

The workflow does not call Cloudflare DNS APIs. Consumers stage the migration:
verify the `pages.dev` deployment, register the custom hostname, switch DNS,
then retain the previous host or DNS value until the new route and certificate
are stable.

## Consequences

- Existing callers are unchanged because the input defaults to an empty string.
- Registration runs only for a successful production Cloudflare deployment,
  never for acceptance, preview, or pull request cleanup.
- The caller remains responsible for DNS ownership, records, cutover timing, and
  rollback.
- The API token needs Pages Write permission but no DNS permission.
- One hostname is supported per workflow invocation. Callers needing multiple
  hostnames can use separate site invocations or a future explicitly designed
  list input.
