#!/usr/bin/env bash
# Remove GeoIPS CI leftovers from a self-hosted runner whose Docker daemon is
# SHARED with other users. Only material this CI creates is touched:
#   - stopped containers labelled geoips-ci=true. reusable-ci.yaml labels every
#     container it starts. Images are deliberately NOT labelled: image labels are
#     published with the image and inherited by every container created from it,
#     so other users' containers would match too.
#   - labelled CI containers still running after CI_ORPHAN_HOURS (default 6; the CI
#     job timeout is 2 hours): left behind by cancelled jobs
#   - images whose tags are all CI tags (geoips:dev-<40-hex commit>[-<run>-<attempt>]
#     or geoips:cache), older than the age limit counted from their last tag time.
#     An image that also has any other tag is kept.
#   - only with PRUNE_DANGLING_GEOIPS_IMAGES=true: dangling (untagged) images whose
#     registry digest is from ${CI_IMAGE_REPO}. Docker cannot tell whether CI or
#     another user pulled them, so this is off by default; reusable-ci.yaml already
#     removes the images its own pulls and tags leave untagged.
#   - weekly, and only with CLEAN_STALE_TESTDATA=true: test_data_* directories in
#     TESTDATA_PATH that were not modified for 30 days (they are re-downloaded)
#   - runner _temp entries older than 2 days
# It never runs docker system/builder/volume prune, never removes other dangling
# or tagged images, never uses `docker rmi -f` (images used by any container are
# kept), and never deletes anything in /tmp.
#
# Usage: runner-prune.sh (--nightly | --weekly) [--dry-run]
#   TESTDATA_PATH                 test data dir (default: ~/.geoips-testdata)
#   CLEAN_STALE_TESTDATA          "true" to allow removing stale test data (weekly only)
#   CI_IMAGE_REPO                 registry repo of the GeoIPS image (default: ghcr.io/nrlmmd-geoips/geoips)
#   PRUNE_DANGLING_GEOIPS_IMAGES  "true" to also remove dangling images from CI_IMAGE_REPO
#   CI_ORPHAN_HOURS               running CI containers older than this are orphans (default: 6)
#
# Written for bash 3.2+ (no arrays). Ages need GNU `date -d`; anything whose age
# cannot be determined is kept.
set -uo pipefail

MODE=""; DRY=false
for a in "$@"; do
  case "$a" in
    --nightly) MODE=nightly ;;
    --weekly) MODE=weekly ;;
    --dry-run) DRY=true ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ -z "$MODE" ] && { echo "Usage: $0 (--nightly|--weekly) [--dry-run]" >&2; exit 2; }

TESTDATA_PATH="${TESTDATA_PATH:-$HOME/.geoips-testdata}"
CLEAN_STALE_TESTDATA="${CLEAN_STALE_TESTDATA:-false}"
CI_IMAGE_REPO="${CI_IMAGE_REPO:-ghcr.io/nrlmmd-geoips/geoips}"
PRUNE_DANGLING_GEOIPS_IMAGES="${PRUNE_DANGLING_GEOIPS_IMAGES:-false}"
CI_ORPHAN_HOURS="${CI_ORPHAN_HOURS:-6}"
case "$CI_ORPHAN_HOURS" in ''|*[!0-9]*) echo "CI_ORPHAN_HOURS must be a number of hours" >&2; exit 2 ;; esac
# Tags reusable-ci.yaml creates; anything else under geoips:dev-* may be a person's.
CI_TAG_RE='^geoips:dev-[0-9a-f]{40}(-[0-9]+-[0-9]+)?$'
# Only images older than this are removed. Nightly keeps two days of history.
if [ "$MODE" = nightly ]; then AGE_HOURS=48; else AGE_HOURS=24; fi
AGE_SECONDS=$((AGE_HOURS * 3600))
now=$(date +%s)

report() {
  df -h / "${TESTDATA_PATH}" 2>/dev/null
  echo "CI images:"
  docker images --filter "reference=geoips:*" || true
  docker images "${CI_IMAGE_REPO}" || true
}

# old_enough <Created (RFC 3339)> <last tag time, epoch seconds, or ""> <label>:
# true if both the creation and the last tag time are older than AGE_HOURS. The
# last tag time matters for images CI re-tagged recently (a pulled image tagged
# geoips:dev-*). Docker reports it via {{.Metadata.LastTagTime.Unix}}.
old_enough() {
  local t1 t2
  [ -n "$1" ] && t1=$(date -d "$1" +%s 2>/dev/null) || t1=""
  if [ -z "$t1" ]; then
    echo "  keep $3 (cannot parse creation time '$1'; needs GNU date)"
    return 1
  fi
  t2=$2
  case "$t2" in ''|*[!0-9-]*) t2=0 ;; esac
  [ "$t2" -gt "$t1" ] && t1=$t2
  if [ $((now - t1)) -le "$AGE_SECONDS" ]; then
    echo "  keep $3 (created or tagged within ${AGE_HOURS}h)"
    return 1
  fi
  return 0
}

is_ci_tag() {
  [ "$1" = "geoips:cache" ] || [[ "$1" =~ $CI_TAG_RE ]]
}

# Running CI containers: skip the prune while a job is using the runner, but do
# not wait forever on containers a cancelled job left running.
running=""; orphans=""
for c in $(docker ps -q --filter label=geoips-ci=true); do
  started=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null) || started=""
  s=""
  [ -n "$started" ] && s=$(date -d "$started" +%s 2>/dev/null) || s=""
  if [ -n "$s" ] && [ $((now - s)) -gt $((CI_ORPHAN_HOURS * 3600)) ]; then
    orphans="$orphans $c"
  else
    running="$running $c"
  fi
done
if [ -n "$orphans" ]; then
  echo "+ CI containers running longer than ${CI_ORPHAN_HOURS}h (left by cancelled jobs):$orphans"
  # shellcheck disable=SC2086
  $DRY || docker rm -f $orphans || true
fi
if [ -n "$running" ]; then
  echo "CI containers are running:$running; skipping prune."
  exit 0
fi

echo "=== Before ($MODE, images older than ${AGE_HOURS}h) ==="; report

echo "+ stopped CI containers (label geoips-ci=true)"
if $DRY; then
  docker ps -a --filter label=geoips-ci=true --filter status=exited || true
else
  docker container prune -f --filter label=geoips-ci=true || true
fi

echo "+ images tagged only with CI tags (geoips:dev-<sha>..., geoips:cache), older than ${AGE_HOURS}h"
ids=$( { docker images --filter "reference=geoips:dev-*" --format '{{.ID}}'
         docker images --filter "reference=geoips:cache" --format '{{.ID}}'; } | sort -u )
for id in $ids; do
  info=$(docker image inspect --format '{{.Created}}|{{.Metadata.LastTagTime.Unix}}|{{join .RepoTags " "}}' "$id") || continue
  created=${info%%|*}; rest=${info#*|}; tagged=${rest%%|*}; tags=${rest#*|}
  other=""
  for t in $tags; do
    is_ci_tag "$t" || other="$other $t"
  done
  if [ -n "$other" ]; then
    echo "  keep $tags (not only CI tags:$other)"
    continue
  fi
  old_enough "$created" "$tagged" "$tags" || continue
  echo "  remove $tags"
  # Untag each CI tag; the image is deleted with its last tag unless a container uses it.
  # shellcheck disable=SC2086
  $DRY || docker rmi $tags || true
done

if [ "$PRUNE_DANGLING_GEOIPS_IMAGES" = "true" ]; then
  echo "+ dangling images from ${CI_IMAGE_REPO}, older than ${AGE_HOURS}h"
  for id in $(docker images --filter dangling=true --format '{{.ID}}'); do
    info=$(docker image inspect --format '{{.Created}}|{{join .RepoDigests " "}}' "$id") || continue
    created=${info%%|*}; digests=${info#*|}
    case " $digests" in
      *" ${CI_IMAGE_REPO}@"*) ;;
      *) continue ;;   # not from the GeoIPS registry repo: never touched
    esac
    old_enough "$created" "" "$id" || continue
    echo "  remove $id"
    $DRY || docker rmi "$id" || true
  done
fi

if [ "$MODE" = weekly ] && [ "$CLEAN_STALE_TESTDATA" = "true" ] && [ -d "$TESTDATA_PATH" ]; then
  echo "+ test_data_* dirs not modified for 30 days in $TESTDATA_PATH"
  if $DRY; then
    find "$TESTDATA_PATH" -maxdepth 1 -type d -name 'test_data_*' -mtime +30 -print
  else
    find "$TESTDATA_PATH" -maxdepth 1 -type d -name 'test_data_*' -mtime +30 -print -exec rm -rf {} + || true
  fi
fi

echo "+ runner _temp entries older than 2 days"
for t in "$HOME"/actions-runner*/_work/_temp; do
  [ -d "$t" ] || continue
  if $DRY; then find "$t" -mindepth 1 -maxdepth 1 -mtime +2 -print
  else find "$t" -mindepth 1 -maxdepth 1 -mtime +2 -print -exec rm -rf {} + 2>/dev/null || true; fi
done

echo "=== After ($MODE) ==="; report
