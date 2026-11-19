#!/usr/bin/env bash
# Runs the image job's "Image name", "Keep the image on the box" and "Clean up" steps from tiered.yml against the
# local Docker daemon with tiny scratch images, and checks what is kept and what is pruned. Run by self-check.yml;
# locally: .github/tests/image-keep.sh (needs docker and ruby). Everything it creates is named ci-tiers-test*.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
REPO=ghcr.io/ci-tiers-test/app
fail=0

ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["jobs"]["image"]["steps"]
  { "Image name" => "name.sh", "Keep the image on the box" => "keep.sh", "Clean up" => "clean.sh" }.each do |n, f|
    File.write(File.join(ARGV[1], f), steps.find { |s| s["name"] == n }.fetch("run"))
  end' "$ROOT/.github/workflows/tiered.yml" "$WORK"

sha() { printf '%040x' "$1"; }
# A distinct tiny image per call (the random label defeats the build cache), one second apart so creation times order.
mk() {
	printf 'FROM scratch\nLABEL t=%s n=%s\nCMD ["/x"]\n' "$1" "$RANDOM$RANDOM" | docker build -q -t "$1" - >/dev/null
	sleep 1.1
}
cleanup() {
	docker ps -aq --filter label=ci-tiers-test=1 | xargs -r docker rm -f >/dev/null
	docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^(ghcr\.io/ci-tiers-test/app|ci-tiers-test-[a-z]+):' \
		| xargs -r docker image rm -f >/dev/null 2>&1 || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT
check() { # check <description> <command...>
	if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
# shellcheck disable=SC2329 # called through check
present() { docker image inspect "$1" >/dev/null 2>&1; }
# shellcheck disable=SC2329
absent() { ! present "$1"; }
# The three steps in order, as the job runs them (GITHUB_ENV carried between steps; the "build" happens in between).
run_steps() {
	export GITHUB_ENV="$WORK/env" GITHUB_STEP_SUMMARY="$WORK/summary" GITHUB_REPOSITORY=org/app CI_LABEL=ci-tiers.run=test
	: >"$GITHUB_ENV"
	: >"$GITHUB_STEP_SUMMARY"
	bash -euo pipefail "$WORK/name.sh"
	set -a
	# shellcheck source=/dev/null
	. "$GITHUB_ENV"
	set +a
	mk "$IMAGE_TAG"
	bash -euo pipefail "$WORK/keep.sh"
	set -a
	# shellcheck source=/dev/null
	. "$GITHUB_ENV"
	set +a
	bash -eo pipefail "$WORK/clean.sh"
}

cleanup
echo "== kept under another name (ghcr.io/...), keep 3, one image in use, one in a tag file"
for i in 1 2 3 4 5 6 7; do mk "$REPO:$(sha "$i")"; done
docker tag "$REPO:$(sha 1)" "$REPO:main"
mk "$REPO:$(sha 8)-branch"
docker create --label ci-tiers-test=1 "$REPO:$(sha 3)" >/dev/null
sha 2 >"$WORK/current_tag"
export GITHUB_SHA INPUT_NAME KEEP_NAME KEEP_COUNT PROTECT
GITHUB_SHA="$(sha 99)" INPUT_NAME=ci-tiers-test-app KEEP_NAME="$REPO" KEEP_COUNT=3
PROTECT="$WORK/current_tag
$WORK/missing/*/.previous_tag"
run_steps
check "this run's image is kept" present "$REPO:$(sha 99)"
check "the newest others are kept (7, 6)" present "$REPO:$(sha 7)"
check "... and 6" present "$REPO:$(sha 6)"
check "older ones are pruned (5)" absent "$REPO:$(sha 5)"
check "... and 4" absent "$REPO:$(sha 4)"
check "the image a container uses is kept (3)" present "$REPO:$(sha 3)"
check "the tag file's tag is kept (2)" present "$REPO:$(sha 2)"
check "an old sha tag is pruned (1)" absent "$REPO:$(sha 1)"
check "a non-sha tag is never touched (:main)" present "$REPO:main"
check "a sha-branch tag is never touched" present "$REPO:$(sha 8)-branch"
check "the build tag is removed" absent "ci-tiers-test-app:$(sha 99)"
check "the summary names the kept image" grep -qF "$REPO:$(sha 99)" "$GITHUB_STEP_SUMMARY"

cleanup
echo "== kept under the build name, a re-run of the commit production runs"
GITHUB_SHA="$(sha 50)" INPUT_NAME=ci-tiers-test-same KEEP_NAME='' KEEP_COUNT=5 PROTECT=''
mk "ci-tiers-test-same:$GITHUB_SHA"
docker create --label ci-tiers-test=1 "ci-tiers-test-same:$GITHUB_SHA" >/dev/null
run_steps
check "the kept tag survives the clean-up" present "ci-tiers-test-same:$GITHUB_SHA"

cleanup
echo "== a bad image-keep-name fails the job"
GITHUB_SHA="$(sha 60)" INPUT_NAME=ci-tiers-test-bad KEEP_NAME='Bad/Name:tag'
export GITHUB_ENV="$WORK/env"; : >"$GITHUB_ENV"
# shellcheck disable=SC2016 # expanded by the inner bash
check "rejected" bash -c '! bash -euo pipefail "$1/name.sh" 2>/dev/null' _ "$WORK"

exit "$fail"
