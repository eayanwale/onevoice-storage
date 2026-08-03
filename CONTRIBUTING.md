# Contributing / Branching Conventions

Conventions for branches, pull requests, labels, and milestones in this repo.

## Branch protection

- `main`/`dev` cannot be pushed to directly. All changes go through a pull request.
- Any PR that touches a `.md` file must come from a branch prefixed `docs/`, enforced via a required status check on PRs targeting the protected branch.

## Branch naming

Format: `type/issue-number-short-slug`

| Type    | Use for                                      |
|---------|-----------------------------------------------|
| feat    | new functionality                             |
| fix     | bug fixes                                     |
| infra   | infrastructure/architecture work (matches the `infra` label) |
| docs    | documentation-only changes (required for any `.md` change) |
| chore   | maintenance, cleanup, non-functional changes  |
| test    | test-only changes                             |

Examples:

```
feat/17-create-r2-buckets
fix/19-r2-auth-migration-mount
infra/24-mcp-server-ec2
docs/26-runbook
chore/21-decommission-ec2
```

## PR titles

Conventional Commits style, referencing the issue number:

```
feat(r2): create primary and migration buckets (#17)
infra(mcp): stand up MCP server on EC2 host (#24)
docs: add runbook (#26)
```

Include `Closes #<issue-number>` in the PR description to auto-close the issue on merge.

## Labels

Existing labels and when to use them:

- `bug` — something isn't working
- `enhancement` — new feature or request
- `documentation` — improvements or additions to documentation
- `infra` — infrastructure/architecture work
- `maintenance` — recurring Nextcloud server maintenance checklist items
- `question` — further information is requested
- `good first issue` / `help wanted` — as needed
- `duplicate` / `invalid` / `wontfix` — triage outcomes
- `test` — test-related work

## Milestones

Format: `vX.Y.0 – Short description`, one milestone per feature batch, tied to the next planned release.

Examples already in use:

```
v1.7.0 – Finish the Cloudflare R2 migration
v1.9.0 – Nextcloud group folders automation
v1.10.0 – Centralized logging via Loki/Grafana
```

Assign each issue/PR to the milestone for the release it's targeting.