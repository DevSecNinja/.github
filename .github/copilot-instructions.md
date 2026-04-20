# DevSecNinja — Copilot Instructions (org-wide)

## Coding Standards

- **Commit messages**: Follow [Conventional Commits](https://www.conventionalcommits.org) — `type(scope): description`.
  - Types: `feat`, `fix`, `docs`, `ci`, `chore`, `refactor`, `perf`, `test`.
- **YAML**: 2-space indent, start with `---`, format with yamlfmt, lint with yamllint.
- **Markdown**: Format with dprint. 4-space indent.
- **Shell scripts**: Bash dialect, 4-space indent, lint with shellcheck, format with shfmt.
- **GitHub Actions**: Pin all action refs to full commit SHAs with a version comment.
  Example: `uses: actions/checkout@<sha> # v4.2.0`
- **Reusable workflows**: Reusable workflows in `DevSecNinja/.github` MUST NOT
  default package / tool version inputs — declare them `required: true` so the
  calling repository owns the version (see
  [ADR 0001](https://github.com/DevSecNinja/.github/blob/main/docs/design-decisions/0001-reusable-workflow-version-inputs.md)).
- **Security**: Never commit plaintext secrets. Use SOPS, Vault, or GitHub Secrets.

## Tool Chain

All linting/formatting tools are managed by [mise](https://mise.jdx.dev/) (`.mise.toml`).
Run tools via `mise exec -- <tool>`.

## Pre-commit

Run `mise exec -- lefthook run pre-commit` before committing.

## File Conventions

- LF line endings, always end files with a newline.
- Indent: 2 spaces (YAML/JSON), 4 spaces (Markdown/shell).

## Repo-specific Instructions

Individual repositories may have their own `.github/copilot-instructions.md`
that supplements or overrides these org-wide defaults.
