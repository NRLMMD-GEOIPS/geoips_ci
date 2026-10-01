#!/usr/bin/env bash
# Safety tests for runner-prune.sh. It runs against a fake `docker` that records
# every call, and the tests check that only CI material is removed, that other
# users' images are never touched, and that --dry-run changes nothing.
#
# Usage: scripts/test-runner-prune.sh     (needs GNU date: Linux, or coreutils on macOS)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
prune="$here/runner-prune.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! date -d @0 +%s >/dev/null 2>&1; then
  echo "test-runner-prune.sh needs GNU date (date -d)" >&2
  exit 2
fi

SHA=0123456789abcdef0123456789abcdef01234567
NEVER=-62135596800                        # Metadata.LastTagTime.Unix of a never-tagged image
NOW=$(date +%s)
NOW_RFC3339=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$work/bin"
cat > "$work/bin/docker" <<EOF
#!/usr/bin/env bash
# Fake docker: logs each call to \$FAKE_LOG and answers runner-prune.sh's queries.
echo "\$*" >> "\$FAKE_LOG"
all="\$*"
case "\$1" in
  ps)
    if [ "\$2" = "-q" ]; then
      case "\${FAKE_RUNNING:-none}" in
        young) echo cYoung ;;
        old)   echo cOld ;;
        both)  printf 'cOld\ncYoung\n' ;;
      esac
    fi ;;
  inspect)                               # container StartedAt
    case "\${@: -1}" in
      cOld)   echo "2025-01-01T00:00:00Z" ;;
      cYoung) echo "$NOW_RFC3339" ;;
    esac ;;
  images)
    case "\$all" in
      *"reference=geoips:dev-*"*"{{.ID}}"*) printf 'iSha\niRun\niPerson\niShared\niRetag\n' ;;
      *"reference=geoips:cache"*"{{.ID}}"*) echo iCache ;;
      *"dangling=true"*) printf 'dOurs\ndOther\n' ;;
    esac ;;
  image)
    [ "\$2" = inspect ] || exit 0
    case "\$all" in
      *LastTagTime*Unix*) ;;
      *LastTagTime*) echo "fake docker: LastTagTime must be read via .Unix" >&2; exit 3 ;;
    esac
    id="\${@: -1}"
    case "\$all" in
      *RepoTags*)
        case "\$id" in
          iSha)    echo "2025-01-01T00:00:00Z|$NEVER|geoips:dev-$SHA" ;;
          iRun)    echo "2025-01-01T00:00:00Z|$NEVER|geoips:dev-$SHA-987654321-2" ;;
          iPerson) echo "2025-01-01T00:00:00Z|$NEVER|geoips:dev-myfeature" ;;
          iShared) echo "2025-01-01T00:00:00Z|$NEVER|geoips:dev-$SHA-77-1 ghcr.io/nrlmmd-geoips/geoips:latest" ;;
          iRetag)  echo "2025-01-01T00:00:00Z|$NOW|geoips:dev-$SHA-5-1" ;;
          iCache)  echo "2025-01-01T00:00:00Z|$NEVER|geoips:cache" ;;
        esac ;;
      *RepoDigests*)
        case "\$id" in
          dOurs)  echo "2025-01-01T00:00:00Z|ghcr.io/nrlmmd-geoips/geoips@sha256:aaa" ;;
          dOther) echo "2025-01-01T00:00:00Z|docker.io/someoneelse/app@sha256:ccc" ;;
        esac ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$work/bin/docker"

fails=0
name=""
# run_case <name> [VAR=value ...] -- <runner-prune.sh args>
run_case() {
  name=$1; shift
  local envs=""
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs="$envs $1"; shift; done
  shift
  rm -rf "$work/td"; mkdir -p "$work/td/test_data_old" "$work/td/test_data_new"
  touch -t 202501010000 "$work/td/test_data_old"
  : > "$work/log"
  # shellcheck disable=SC2086
  env FAKE_LOG="$work/log" PATH="$work/bin:$PATH" TESTDATA_PATH="$work/td" HOME="$work/home" \
    $envs bash "$prune" "$@" > "$work/out" 2>&1
  status=$?
  if grep -qE "unbound variable|syntax error|command not found|fake docker:" "$work/out"; then
    fail "script error: $(grep -E 'unbound variable|syntax error|command not found|fake docker:' "$work/out" | head -1)"
  fi
}
fail() { echo "FAIL [$name]: $1"; fails=$((fails + 1)); }
expect_call() { grep -qxF -- "$1" "$work/log" || fail "expected docker $1"; }
reject_call() {
  if grep -qE -- "$1" "$work/log"; then
    fail "unexpected docker call: $(grep -E -- "$1" "$work/log" | head -1)"
  fi
}
expect_status() { [ "$status" = "$1" ] || fail "exit status $status, expected $1"; }
no_changes() { reject_call '^(rmi|rm |container prune|image prune|system|builder|volume|network)'; }
never_allowed() {
  reject_call '^(system|builder|volume|network|image prune)'
  reject_call '^rmi( .*)? -f( |$)'                 # force-removing an image
  reject_call '^rm -f .*cYoung'                    # a container of a running job
  reject_call '^rmi .*geoips:dev-myfeature'        # a person's tag
  reject_call '^rmi .*ghcr\.io/'                   # a shared, registry-tagged image
  reject_call '^rmi .*-77-1'                       # CI tag on an image that also has another tag
  reject_call '^rmi dOther'                        # someone else's dangling image
}

run_case "nightly" -- --nightly
expect_status 0
expect_call "container prune -f --filter label=geoips-ci=true"
expect_call "rmi geoips:dev-$SHA"
expect_call "rmi geoips:dev-$SHA-987654321-2"
expect_call "rmi geoips:cache"
reject_call "^rmi geoips:dev-$SHA-5-1"             # re-tagged just now
reject_call '^rmi dOurs'                           # dangling removal is opt-in
never_allowed
[ -d "$work/td/test_data_old" ] || fail "nightly removed test data"

run_case "nightly dry-run" -- --nightly --dry-run
expect_status 0; no_changes

run_case "weekly, dangling opt-in" PRUNE_DANGLING_GEOIPS_IMAGES=true -- --weekly
expect_status 0
expect_call "rmi dOurs"
never_allowed
[ -d "$work/td/test_data_old" ] || fail "test data removed without CLEAN_STALE_TESTDATA=true"

run_case "weekly, stale test data opt-in" CLEAN_STALE_TESTDATA=true -- --weekly
expect_status 0
[ -d "$work/td/test_data_old" ] && fail "stale test data was not removed"
[ -d "$work/td/test_data_new" ] || fail "fresh test data was removed"
never_allowed

run_case "weekly dry-run, everything opted in" CLEAN_STALE_TESTDATA=true PRUNE_DANGLING_GEOIPS_IMAGES=true -- --weekly --dry-run
expect_status 0; no_changes
[ -d "$work/td/test_data_old" ] || fail "dry-run removed test data"

run_case "CI job running" FAKE_RUNNING=young -- --weekly
expect_status 0; no_changes
grep -q "skipping prune" "$work/out" || fail "did not report skipping"

run_case "orphaned CI container" FAKE_RUNNING=old -- --nightly
expect_status 0
expect_call "rm -f cOld"
expect_call "rmi geoips:cache"
reject_call '^rm -f .*cYoung'
never_allowed

run_case "orphan while a CI job runs" FAKE_RUNNING=both -- --nightly
expect_status 0
expect_call "rm -f cOld"
reject_call '^rmi'
reject_call '^rm -f .*cYoung'

run_case "orphan, dry-run" FAKE_RUNNING=old -- --nightly --dry-run
expect_status 0; no_changes

run_case "bad argument" -- --sometimes
expect_status 2; no_changes

run_case "bad CI_ORPHAN_HOURS" CI_ORPHAN_HOURS=six -- --nightly
expect_status 2; no_changes

if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "runner-prune.sh: all safety checks passed"
