# DevSecNinja/.github

Org-level GitHub configuration and shared automation for all **DevSecNinja**
repositories.

| What                       | Where                                                          |
| -------------------------- | -------------------------------------------------------------- |
| Reusable workflows         | [`.github/workflows/`](.github/workflows/)                     |
| Workflow templates         | [`workflow-templates/`](workflow-templates/)                    |
| Config sync (files)        | [`config-sync/files/`](config-sync/files/)                     |
| Config sync (templates)    | [`config-sync/templates/`](config-sync/templates/)             |
| Renovate presets           | [`.renovate/`](.renovate/)                                     |
| Design decisions (ADRs)    | [`docs/design-decisions/`](docs/design-decisions/README.md)    |
| Architecture & usage guide | [`docs/architecture.md`](docs/architecture.md)                 |

## Development

```sh
mise install                          # install all tools
mise exec -- lefthook run pre-commit  # run linters
```

Commit with [Conventional Commits](https://www.conventionalcommits.org).
See the [`commit-and-release`](.github/skills/commit-and-release/SKILL.md) skill
for a step-by-step guide including releases with `cog bump`.

## License

[MIT](LICENSE)
