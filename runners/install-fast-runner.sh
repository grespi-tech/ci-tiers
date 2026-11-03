#!/usr/bin/env bash
# Register a "fast" GitHub Actions runner (labels self-hosted,ci-fast) on this
# box, as a systemd service inside ci-fast.slice. Run as root on the box.
#
#   sudo ./install-fast-runner.sh <scope-url> <name> [runner-version]
#
#   scope-url   https://github.com/<org>            (organisation runner)
#               https://github.com/<owner>/<repo>  (repository runner)
#   name        udb-ci-fast-paqett, udb-ci-fast-grespi, udb-ci-fast-sparsh ...
#
# The registration token is read from the GH_RUNNER_TOKEN environment variable
# (never from an argument, so it is not in the process list or shell history):
#   GH_RUNNER_TOKEN=$(gh api -X POST orgs/<org>/actions/runners/registration-token --jq .token)
#   GH_RUNNER_TOKEN=$(gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token)
#
# Idempotent: re-running with the same name reconfigures. Does not touch the
# existing heavy runners (label ci) or their slice.
set -euo pipefail

scope="${1:?scope url}"
name="${2:?runner name}"
version="${3:-2.330.0}"
: "${GH_RUNNER_TOKEN:?set GH_RUNNER_TOKEN to a registration token}"
user="${RUNNER_USER:-runner}"
base="${RUNNER_BASE:-/opt/actions-runners}"
dir="$base/$name"

if ! id "$user" >/dev/null 2>&1; then
  echo "user $user does not exist; set RUNNER_USER to the account the heavy runners use" >&2
  exit 1
fi

install -d -o "$user" -g "$user" "$dir"
if [ ! -x "$dir/run.sh" ]; then
  tarball="actions-runner-linux-x64-${version}.tar.gz"
  curl -sSfL -o "/tmp/$tarball" "https://github.com/actions/runner/releases/download/v${version}/${tarball}"
  # Checksum from the release page; refuse to install without it.
  curl -sSfL "https://github.com/actions/runner/releases/download/v${version}/${tarball}.sha256" 2>/dev/null \
    | sed "s#  .*#  /tmp/$tarball#" | sha256sum -c - || {
      echo "no checksum published for v${version}; verify /tmp/$tarball by hand and re-run with it unpacked in $dir" >&2
      exit 1
    }
  tar -xzf "/tmp/$tarball" -C "$dir"
  chown -R "$user:$user" "$dir"
  rm -f "/tmp/$tarball"
fi

# Slice first, so the service drop-in below can reference it.
install -m 0644 "$(dirname "$0")/ci-fast.slice" /etc/systemd/system/ci-fast.slice
systemctl daemon-reload

sudo -u "$user" env GH_RUNNER_TOKEN="$GH_RUNNER_TOKEN" bash -c "
  cd '$dir' &&
  ./config.sh --unattended --replace \
    --url '$scope' --token \"\$GH_RUNNER_TOKEN\" \
    --name '$name' --labels ci-fast --work _work \
    --disableupdate
"

(cd "$dir" && ./svc.sh install "$user" >/dev/null)
svc="$(find /etc/systemd/system -maxdepth 1 -name "actions.runner.*${name}*.service" -printf '%f\n' | head -n1)"
[ -n "$svc" ] || { echo "svc.sh did not create a unit for $name" >&2; exit 1; }
install -d "/etc/systemd/system/${svc}.d"
cat > "/etc/systemd/system/${svc}.d/slice.conf" <<CONF
[Service]
Slice=ci-fast.slice
Nice=10
IOSchedulingClass=idle
# The fast tier runs no containers; keep docker.sock out of reach of its jobs.
Environment=DOCKER_HOST=unix:///nonexistent
CONF
systemctl daemon-reload
systemctl enable --now "$svc"
systemctl --no-pager status "$svc" | head -n 5
echo "runner $name registered with labels self-hosted,ci-fast in ci-fast.slice"
echo "callers: set runs-on-fast to [\"self-hosted\", \"ci-fast\"]"
