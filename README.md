# ci-tiers

Tiered CI for the Paqett and Sparsh repositories, all on the self-hosted box.
One reusable workflow decides how much pipeline a change deserves, so a
stacked pull request costs a typecheck and only the pull request into `main`
pays for the image build.

| Tier | Jobs | When |
| --- | --- | --- |
| 0 | nothing (gate is green) | draft PR, PR from a fork, docs-only change, label `ci:skip` (anyone with triage rights can apply it: an intentional bypass, visible in the run summary) |
| 1 | `fast` (typecheck, lint, cheap build), optional `secret scan` | any other PR, any branch push |
| 2 | + `test` (unit and integration, throwaway Postgres) | push to `integration/*`, label `ci:test` |
| 3 | + `e2e setup`, `e2e` (Playwright), `image` (build, token check, smoke, kept on the box for the deploy script) | PR into `main`, push to `main`, label `ci:full` |

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
    # labeled/unlabeled so a ci:* label takes effect without a push.
    types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]
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
    uses: grespi-tech/ci-tiers/.github/workflows/tiered.yml@v1.1.0
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
      # Always ${PGHOST}:${PGPORT}: 127.0.0.1 on the host jobs, the Postgres
      # container's name inside the E2E container.
      env: |
        DATABASE_URL=postgres://postgres:postgres@${PGHOST}:${PGPORT}/app_test
      e2e-image: mcr.microsoft.com/playwright:v1.64.1-noble   # tag MUST match @playwright/test
      e2e: pnpm test:e2e
      image: true
      image-secret-id: npm_token   # the Dockerfile's --mount=type=secret,id=...
      # Kept on the box as <image-keep-name>:<sha>, the name the deploy script runs; see "Images on the box".
      image-keep-name: ghcr.io/example/app
      image-keep-protect: |
        /opt/app/.current_tag
        /opt/app/.previous_tag
      # $CI_LABEL on every container you start: the job's clean-up removes
      # whatever carries it, even if a line below fails. Pick a free port;
      # the smoke container shares the box's host network.
      image-smoke: |
        name="smoke-$GITHUB_RUN_ID"; port=$((20000 + GITHUB_RUN_ID % 10000))
        docker run -d --rm --name "$name" --label "$CI_LABEL" --network host -e PORT=$port \
          -e DATABASE_URL=postgres://postgres:postgres@127.0.0.1:${PGPORT}/app_test "$IMAGE_TAG"
        for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy ] && break; sleep 3; done
        docker logs "$name"; [ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" = healthy ]
        docker rm -f "$name"
```

`pull_request` has no `branches:` filter on purpose: PRs into `integration/*`
and PRs stacked on another PR's branch must trigger, and they get tier 1.

Pin an exact tag (`@v1.1.0`). Tags are never moved once a caller uses them; a
fix is a new tag. The workflow references its own composite actions at the
same tag, and `self-check.yml` fails a tagged commit whose references do not
match its tag.

## Inputs

Commands (one per line, first failure fails the job): `fast` (required),
`test`, `e2e-setup`, `e2e` (default `pnpm exec playwright test`; `--shard=i/n`
appended), `e2e-build` (default `pnpm build`), `image-smoke`.

E2E: `e2e-image` (empty = no E2E), `e2e-shards` (`'[1]'`), `e2e-report-path`,
`e2e-container-cpus` (2), `e2e-container-memory` (3g), `e2e-container-options`.

Image: `image` (false), `image-name` (repository name), `image-context` (`.`),
`image-build-args` (e.g. `--file deploy/Dockerfile`), `image-secret-id`
(`npm_token`), `image-keep-local` (true), `image-keep-name` (the image name),
`image-keep-count` (5), `image-keep-protect` (empty), `image-artifact` (false),
`image-retention-days` (7, artifact only). The build gets the npm token as a
BuildKit secret only; the job fails if the token or an `authToken` npmrc is
found in the image. `$IMAGE_TAG` names the built image in `image-smoke`.

E2E reports (`e2e-report-path`) are uploaded only when the E2E job fails, and
kept 3 days.

Environment: `postgres` (image; empty = none), `postgres-databases`, `env`
(`KEY=VALUE` lines; `${PGHOST}`, `${PGPORT}` etc. expand at runtime), `secret-names`,
`node-version` (22), `pnpm-version` (empty = corepack + `packageManager`),
`npm-scope`, `npm-registry`, `gitleaks` (false).

Tiering: `tier` (`auto` or 0-3), `main-branch` (`main`), `integration-prefix`
(`integration/`), `docs-paths` (glob lines; default covers `**/*.md`, `docs/**`,
`documentation/**`, `LICENSE`, issue and PR templates).

Runners: `runs-on-fast` (`["self-hosted","ci"]`; switch to `ci-fast` after
installing the fast runners, see `runners/README.md`), `runs-on-heavy`,
`timeout-fast` (135), `timeout-test` (150), `timeout-e2e` (165), `timeout-image` (150).
Each includes up to 120 minutes queued behind the box-wide CI lock: the
runners' job-started hook holds a job in "Set up runner" until the lock and
enough free disk are available, and that wait counts against the job's limit.

## Images on the box

The runners use the box's own Docker daemon, which is also production's, so
the image the `image` job built and smoke-tested is already where it will be
deployed. With `image-keep-local: true` (the default) it stays there:

- **Name.** After the smoke test it is tagged `<image-keep-name>:<full commit
  sha>`, the name the deploy script runs (for example
  `ghcr.io/paqett/console`); the build's own tag is removed if it differs. A
  deploy is then just `deploy.sh --local <sha>`: no download, no `docker load`.
- **Not for pull requests.** A `pull_request` run builds from a temporary merge
  commit that is never deployed, so its image is not kept.
- **Pruning.** The kept images of that name are the tags that are a full
  40-hex commit sha (`:main` or `:<sha>-<branch>` from a registry are never
  touched). After keeping its own, the job keeps the newest `image-keep-count`
  (by creation time) and removes the older ones, except an image any
  container uses (running or stopped, by name or by id) and the tags written
  in the `image-keep-protect` files (one tag per file, e.g. a deploy
  directory's `.current_tag` and `.previous_tag`; globs allowed). Removal is
  `docker image rm` without `-f`, so Docker itself also refuses an image a
  container still needs. The summary and the log list what was kept and why.
- **Unreadable tag files.** The runner user (`gha-runner`) may not be able to
  read them (a 0700 deploy directory). They are reported with a notice and
  skipped: the running release is still protected by its container, and the
  previous one by being among the newest `image-keep-count`. A rollback to an
  older pruned build needs the artifact (below) or a registry pull.
- **Disk.** Images of one repository share their base layers, so each extra
  kept build costs only its changed layers; `image-keep-count` bounds it. The
  runners' job-started hook still refuses to start a job on a nearly full disk.
- **The artifact** is still there when wanted: `image-artifact: true` also
  saves the image (`docker save | gzip`, its build name) and uploads it as
  `<image-name>-image-<sha>` for `image-retention-days`. It counts against the
  owner's GitHub storage, which on a free plan is 0.5 GB measured in GB-hours
  over the month (a 100 MB artifact kept 7 days is about 17 GB-hours); a full
  quota also blocks GitHub Packages publishing. Callers can expose it as a
  `workflow_dispatch` input for the rare run that needs one.

`image-keep-local: false` with `image-artifact: false` builds and smoke-tests
the image and keeps nothing.

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

## Visibility and allow-listing

This repository must be **public**: a reusable workflow in a private
repository is only callable from the same owner, and the callers live in the
paqett organisation and a personal account. (It was created private and is
made public by the owner.)

An organisation that restricts actions must allow `grespi-tech/ci-tiers/*`
(that pattern covers the workflow and the composite actions). The paqett
organisation already allows `grespi-tech/ci-workflows/*`; add this one next to
it:

```sh
gh api -X PUT orgs/paqett/actions/permissions/selected-actions --input - <<'EOF'
{"github_owned_allowed":true,"verified_allowed":false,
 "patterns_allowed":["grespi-tech/ci-workflows/*","grespi-tech/ci-workflows@*",
   "grespi-tech/ci-tiers/*","paqett/*",
   "pnpm/action-setup@fc06bc1257f339d1d5d8b3a19a8cae5388b55320"]}
EOF
```

This workflow uses only GitHub-owned actions plus its own composite actions,
so no third-party pattern is needed: pnpm comes from corepack, not
`pnpm/action-setup`.

`GITHUB_TOKEN` reads a `@paqett/*` package only if that package grants the
calling repository access (package settings, "Manage Actions access"); until
then the install answers 401 and the caller needs `NPM_TOKEN`.

## Security

Every job runs on self-hosted runners that share a box with production. That
is a deliberate choice by the owner, with two mitigations built in: a pull
request whose head is another repository is always tier 0, so fork code never
executes on the box, and the fast tier's runners should run with no Docker
socket (`runners/`). Jobs still execute the pull request's own code (its
package scripts, its tests); only people who can push to these repositories
can reach the runners.

## Design notes

- `plan` and `gate` run on the fast runner for a few seconds each. They are
  the price of a single stable check name and a tier the logs explain.
- No `actions/cache`: the pnpm store on the box is shared by every job.
- Job containers (Postgres, Playwright) run under dockerd, outside the
  runners' cgroup, so each one is capped with `--cpus`/`--memory` and
  `--cpu-shares 256` so production wins contention.
- The E2E job is a host job that runs install, build and tests inside the
  Playwright image on a bridge network of its own, shared only with its
  Postgres, rather than a `container:` job: that is what lets it start the
  throwaway Postgres, mount the box's pnpm store, keep its listening ports
  off the host network, and hand the container exactly the caller's
  variables (by name) and nothing of the runner's own.
- Checkouts do not persist credentials, so no token can reach an image, an
  artifact or the E2E container through `.git/config`.
- Every container started by the workflow carries `ci-tiers.run=<run id>`
  and is removed by the job's clean-up step whatever happened before.
- `docker build` runs inside the buildx builder named `ci` when the box has
  one (`runners/README.md` shows how to create it with CPU and memory caps);
  without it the build is uncapped, the one step here that is.
- The repository's own lint (`self-check.yml`) is the one thing on a
  GitHub-hosted runner: this repository is public and the box's runner groups
  refuse public repositories.
- Relation to `grespi-tech/ci-workflows`: same author, same conventions, and
  the `export-env` action is vendored from its v1.3.0. This repository adds the
  tiering, the gate, gitleaks and the image stage; callers move from one to
  the other, they do not combine them.

## History

- `v1.0.0`: first release.
- `v1.0.1`: job time limits include up to 120 min queued behind the box-wide
  CI lock (v1.0.0's 5-min plan limit expired while a Sparsh E2E run held it).
- `v1.1.0`: the image is kept on the box for the deploy scripts
  (`image-keep-local`, `image-keep-name`, `image-keep-count`,
  `image-keep-protect`) instead of round-tripping through a GitHub artifact,
  which is now opt-in (`image-artifact`, default false). Playwright reports
  are uploaded only on failure and kept 3 days. The image job's clean-up
  removes only its own containers (it used to kill a concurrent E2E job's,
  exit 137), and never untags an image a container runs. Upgrading: a caller
  that deployed from the artifact sets `image-keep-name` to its deploy
  script's image name, or `image-artifact: true` to keep the old behaviour.
