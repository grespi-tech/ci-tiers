# Runners on the box

Everything runs on udb-hetzner. Two kinds of runner:

| Label | Tier | What runs | Concurrency | Containers |
| --- | --- | --- | --- | --- |
| `ci` (existing: udb-ci-paqett, udb-ci-1, udb-ci-sparsh) | 2 and 3 | tests with Postgres, Playwright, image builds | one job at a time per scope | yes |
| `ci-fast` (new, this folder) | 1 | plan, typecheck, lint, gitleaks, gate | two runners share one vCPU | no |

Until a `ci-fast` runner exists for a scope, callers leave `runs-on-fast` at
its default `["self-hosted", "ci"]` and the fast jobs queue behind the heavy
ones. They are small, so that is tolerable; the split just removes the wait.

## Install a fast runner

One per scope that has a heavy runner today: the paqett organisation, the
grespi-tech organisation, and the sparsh-web-platform repository.

```sh
# on the box, as root, from a checkout of this repository
GH_RUNNER_TOKEN=$(gh api -X POST orgs/paqett/actions/runners/registration-token --jq .token) \
  ./runners/install-fast-runner.sh https://github.com/paqett udb-ci-fast-paqett
GH_RUNNER_TOKEN=$(gh api -X POST orgs/grespi-tech/actions/runners/registration-token --jq .token) \
  ./runners/install-fast-runner.sh https://github.com/grespi-tech udb-ci-fast-grespi
GH_RUNNER_TOKEN=$(gh api -X POST repos/AlessioGrespi/sparsh-web-platform/actions/runners/registration-token --jq .token) \
  ./runners/install-fast-runner.sh https://github.com/AlessioGrespi/sparsh-web-platform udb-ci-fast-sparsh
```

`RUNNER_USER` defaults to `runner`; set it to whatever account the existing
runners use (`systemctl cat actions.runner.*` shows it). The script installs
`ci-fast.slice` (1 vCPU, 2 GB, low IO weight, nice 10) and a drop-in that
puts the service in it. The fast tier never starts containers, so the drop-in
also points `DOCKER_HOST` at nothing.

Then switch the callers: `runs-on-fast: '["self-hosted", "ci-fast"]'`.

## Capped image builds and registry pulls

Tier 3's `docker build` is the one step that would otherwise run uncapped.
Create a builder once and the workflow uses it automatically:

```sh
docker buildx create --name ci --driver docker-container \
  --driver-opt cpu-quota=200000,memory=3g,cpu-shares=256 --bootstrap
```

Docker Hub allows a few anonymous pulls an hour per IP; pre-pull or log in
once as the runner user so `postgres:17` and the Playwright image never fail
a run (`docker login` with a read-only token, or `docker pull` them now).

## Disk

Tier 3 removes its image and smoke containers at the end of every run, but
BuildKit's cache and the shared pnpm store grow. A weekly
`docker builder prune --filter until=168h -f` and `pnpm store prune` as the
runner user keep them bounded. The disk guards and the one-job lock on the
heavy runners are managed outside this repository; nothing here changes them.

## What was not done

Nothing in this folder has been applied to the box. The heavy runners, their
cgroup slice, the disk guards and the one-job lock are untouched.
