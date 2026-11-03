# ci-tiers

Tiered CI for the Paqett and Sparsh repositories, all on the self-hosted box.
One reusable workflow decides how much pipeline a change deserves, so a
stacked pull request costs a typecheck and only the pull request into `main`
pays for the image build.

| Tier | Jobs | When |
| --- | --- | --- |
| 0 | nothing (gate is green) | draft PR, docs-only change, label `ci:skip` |
| 1 | `fast` (typecheck, lint, cheap build), optional `secret scan` | any other PR, any branch push |
| 2 | + `test` (unit and integration, throwaway Postgres) | push to `integration/*`, label `ci:test` |
| 3 | + `e2e setup`, `e2e` (Playwright), `image` (build, token check, smoke, `docker save` artifact) | PR into `main`, push to `main`, label `ci:full` |

Each tier waits for the one below it: a lint failure never spends the heavy
slot. The `gate` job is the single check to require in branch protection
(`ci / gate`): green when every job that ran passed, skipped jobs do not count.

A docs-only change is detected with the compare API, not `paths-ignore`, so
the gate still reports on docs PRs instead of leaving a required check missing.

## Caller

```yaml
# .github/workflows/ci.yml
name: ci
on:
  push:
    branches: [main, 'integration/**']
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      tier:
        type: choice
        options: [auto, '1', '2', '3']
        default: auto

# A re-push cancels the stale run for the same ref instead of queueing behind it.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  packages: read

jobs:
  ci:
    # Drafts do not even start a run; marking "ready for review" does.
    if: github.event_name != 'pull_request' || !github.event.pull_request.draft
    uses: grespi-tech/ci-tiers/.github/workflows/tiered.yml@v1.0.0
    secrets: inherit               # same owner only; see Secrets
    with:
      tier: ${{ inputs.tier || 'auto' }}
      npm-scope: '@paqett'         # GitHub Packages via the caller's GITHUB_TOKEN
      fast: |
        pnpm typecheck
        pnpm lint
      test: |
        pnpm test
      postgres: postgres:17
      postgres-databases: app_test
      env: |
        DATABASE_URL=postgres://postgres:postgres@127.0.0.1:${PGPORT}/app_test
      e2e-image: mcr.microsoft.com/playwright:v1.64.1-noble   # tag MUST match @playwright/test
      e2e: pnpm test:e2e
      image: true
      image-secret-id: npm_token   # the Dockerfile's --mount=type=secret,id=...
      image-smoke: |
        docker run -d --name smoke --network host -e DATABASE_URL=postgres://postgres:postgres@127.0.0.1:${PGPORT}/app_test "$IMAGE_TAG"
        for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' smoke)" = healthy ] && break; sleep 3; done
        docker logs smoke; [ "$(docker inspect -f '{{.State.Health.Status}}' smoke)" = healthy ]
        docker rm -f smoke
```

`pull_request` has no `branches:` filter on purpose: PRs into `integration/*`
and PRs stacked on another PR's branch must trigger, and they get tier 1.

Pin an exact tag (`@v1.0.0`). Tags are never moved; a fix is a new tag.

## Inputs

Commands (one per line, first failure fails the job): `fast` (required),
`test`, `e2e-setup`, `e2e` (default `pnpm exec playwright test`; `--shard=i/n`
appended), `e2e-build` (default `pnpm build`), `image-smoke`.

E2E: `e2e-image` (empty = no E2E), `e2e-shards` (`'[1]'`), `e2e-report-path`,
`e2e-container-cpus` (2), `e2e-container-memory` (3g), `e2e-container-options`.

Image: `image` (false), `image-name` (repository name), `image-context` (`.`),
`image-build-args` (e.g. `--file deploy/Dockerfile`), `image-secret-id`
(`npm_token`), `image-retention-days` (7). The build gets the npm token as a
BuildKit secret only; the job fails if the token or an `authToken` npmrc is
found in the image. `$IMAGE_TAG` names the built image in `image-smoke`.

Environment: `postgres` (image; empty = none), `postgres-databases`, `env`
(`KEY=VALUE` lines, `${PGPORT}` etc. expand at runtime), `secret-names`,
`node-version` (22), `pnpm-version` (empty = corepack + `packageManager`),
`npm-scope`, `npm-registry`, `gitleaks` (false).

Tiering: `tier` (`auto` or 0-3), `main-branch` (`main`), `integration-prefix`
(`integration/`), `docs-paths` (glob lines; default covers `**/*.md`, `docs/**`,
`documentation/**`, `LICENSE`, issue and PR templates).

Runners: `runs-on-fast` (`["self-hosted","ci"]`; switch to `ci-fast` after
installing the fast runners, see `runners/README.md`), `runs-on-heavy`,
`timeout-fast` (15), `timeout-test` (30), `timeout-e2e` (45), `timeout-image` (30).

## Secrets

Same owner as this repository (grespi-tech): `secrets: inherit` and
`secret-names: A B C`.

Another owner (the paqett organisation, a personal-account repository):
`inherit` passes nothing across owners, so pass `KEY=VALUE` lines:

```yaml
    secrets:
      ENV_SECRETS: |
        AWS_ACCESS_KEY_ID=${{ secrets.AWS_ACCESS_KEY_ID }}
        AWS_SECRET_ACCESS_KEY=${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

Every exported value is registered with `::add-mask::` before it is written.
`NPM_TOKEN` is only needed when the caller's `GITHUB_TOKEN` cannot read the
`npm-scope` packages (another owner's packages).

## Allow-listing

An organisation that restricts actions must allow
`grespi-tech/ci-tiers/*` and `grespi-tech/ci-tiers@*`. The paqett organisation
does (alongside `grespi-tech/ci-workflows`). This workflow uses only
GitHub-owned actions plus its own composite actions, so no third-party
pattern is needed: pnpm comes from corepack, not `pnpm/action-setup`.

## Design notes

- `plan` and `gate` run on the fast runner for a few seconds each. They are
  the price of a single stable check name and a tier the logs explain.
- No `actions/cache`: the pnpm store on the box is shared by every job.
- Job containers (Postgres, Playwright) run under dockerd, outside the
  runners' cgroup, so each one is capped with `--cpus`/`--memory` and
  `--cpu-shares 256` so production wins contention.
- The repository's own lint (`self-check.yml`) is the one thing on a
  GitHub-hosted runner: this repository is public and the box's runner groups
  refuse public repositories.
- Relation to `grespi-tech/ci-workflows`: same author, same conventions, and
  the `export-env` action is vendored from its v1.3.0. This repository adds the
  tiering, the gate, gitleaks and the image stage; callers move from one to
  the other, they do not combine them.

## History

- `v1.0.0`: first release.
