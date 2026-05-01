# DevSecNinja/.github

Org-level GitHub configuration and shared automation for all **DevSecNinja**
repositories.

| What                       | Where                                                          |
| -------------------------- | -------------------------------------------------------------- |
| Reusable workflows         | [`.github/workflows/`](.github/workflows/)                     |
| Composite actions          | [`actions/`](actions/)                                         |
| Workflow templates         | [`workflow-templates/`](workflow-templates/)                   |
| Config sync (files)        | [`config-sync/files/`](config-sync/files/)                     |
| Config sync (templates)    | [`config-sync/templates/`](config-sync/templates/)             |
| Renovate presets           | [`.renovate/`](.renovate/)                                     |
| Design decisions (ADRs)    | [`docs/design-decisions/`](docs/design-decisions/README.md)    |
| Architecture & usage guide | [`docs/architecture.md`](docs/architecture.md)                 |
| Release Please onboarding  | [`docs/release-please-onboarding.md`](docs/release-please-onboarding.md) |

## Development

```sh
mise install                          # install all tools
mise exec -- lefthook run pre-commit  # run linters
```

Commit with [Conventional Commits](https://www.conventionalcommits.org).
Releases are automated via
[release-please](docs/release-please-onboarding.md) — every push to
`main` opens or updates a `chore(main): release vX.Y.Z` PR. Merge to
ship.

## License

[MIT](LICENSE)
