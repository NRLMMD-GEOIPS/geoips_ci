#!/usr/bin/env bash
# Remove GeoIPS CI leftovers from a self-hosted runner whose Docker daemon is
# SHARED with other users. Only CI-owned material is touched:
#   - stopped containers labelled geoips-ci=true
#   - unused images labelled geoips-ci=true (built by reusable-ci.yaml)
#   - older CI images without that label (built before labelling existed): images
#     whose ONLY tag is geoips:dev-* or geoips:cache
#   - superseded dangling images pulled from ${CI_IMAGE_REPO} (the GeoIPS base image)
#   - stale test_data_* dirs in TESTDATA_PATH (weekly)
#   - geoips*/pytest-of-* items in /tmp and old runner _temp entries
# It never runs docker system/builder/volume prune and never removes dangling
# or third-party images. Images still used by a container are never removed.
#
# Usage: runner-prune.sh (--nightly | --weekly) [--dry-run]
#   TESTDATA_PATH  test data dir (default: ~/.geoips-testdata)
#   CI_IMAGE_REPO  registry repo of the base image (default: ghcr.io/nrlmmd-geoips/geoips)
#
# Written for bash 3.2+ (no arrays, no GNU-only options except `date -d`, which
# is only used to age-check legacy images and is skipped if unavailable).
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
# Registry repository the CI pulls the GeoIPS base image from (lowercase).
CI_IMAGE_REPO="${CI_IMAGE_REPO:-ghcr.io/nrlmmd-geoips/geoips}"
# Only images older than this are removed. Nightly keeps two days of history.
if [ "$MODE" = nightly ]; then AGE_HOURS=48; else AGE_HOURS=24; fi
AGE_SECONDS=$((AGE_HOURS * 3600))

report() {
  df -h / /tmp "${TESTDATA_PATH}" 2>/dev/null
  echo "CI images:"
  docker images --filter "label=geoips-ci=true" || true
  docker images --filter "reference=geoips:dev-*" || true
  docker images --filter "reference=geoips:cache" || true
}

# Skip while a CI container is running on this host.
if [ -n "$(docker ps -q --filter label=geoips-ci=true)" ]; then
  echo "CI containers are running; skipping prune."
  exit 0
fi

echo "=== Before ($MODE, images older than ${AGE_HOURS}h) ==="; report

echo "+ stopped CI containers (label geoips-ci=true)"
if $DRY; then
  docker ps -a --filter label=geoips-ci=true --filter status=exited || true
else
  docker container prune -f --filter label=geoips-ci=true || true
fi

# `docker image prune` is the only image command with an `until` filter. With
# label=geoips-ci=true it only considers our images, and it never removes an
# image that a container still references.
echo "+ unused CI-labelled images older than ${AGE_HOURS}h"
if $DRY; then
  echo "(dry run: would run docker image prune -a -f --filter label=geoips-ci=true --filter until=${AGE_HOURS}h)"
  docker images --filter "label=geoips-ci=true" || true
else
  docker image prune -a -f --filter "label=geoips-ci=true" --filter "until=${AGE_HOURS}h" || true
fi

# Older CI images have no label. Match by our tag names, but only when that tag is
# the image's only tag: a retagged shared image (plugin runs tag the pulled org
# image as geoips:dev-<sha>) would give no disk benefit and could race a live run.
echo "+ unlabelled legacy CI images (sole tag geoips:dev-* or geoips:cache) older than ${AGE_HOURS}h"
now=$(date +%s)
for pattern in 'geoips:dev-*' 'geoips:cache'; do
  for ref in $(docker images --filter "reference=${pattern}" --format '{{.Repository}}:{{.Tag}}'); do
    info=$(docker image inspect --format '{{.Created}} {{len .RepoTags}}' "$ref") || continue
    created=${info%% *}; ntags=${info##* }
    [ "$ntags" = "1" ] || { echo "  keep $ref (image has $ntags tags)"; continue; }
    created_epoch=$(date -d "$created" +%s 2>/dev/null) || created_epoch=""
    if [ -z "$created_epoch" ]; then
      echo "  keep $ref (cannot parse creation time '$created'; needs GNU date)"
      continue
    fi
    if [ $((now - created_epoch)) -le "$AGE_SECONDS" ]; then
      echo "  keep $ref (newer than ${AGE_HOURS}h)"
      continue
    fi
    echo "  remove $ref"
    # No -f: an image in use by any container is left alone.
    $DRY || docker rmi "$ref" || true
  done
done

# Plugin runs pull the GeoIPS base image; when its tag moves, the previous image
# becomes an unlabelled dangling image. A registry-pulled image keeps its
# RepoDigests, so it can be identified as ours by repository and removed. Other
# dangling images (other users') are never touched.
echo "+ superseded dangling images pulled from ${CI_IMAGE_REPO} older than ${AGE_HOURS}h"
for id in $(docker images --filter dangling=true --format '{{.ID}}'); do
  info=$(docker image inspect --format '{{.Created}}|{{range .RepoDigests}}{{.}} {{end}}' "$id") || continue
  created=${info%%|*}; digests=${info#*|}
  case " $digests" in
    *" ${CI_IMAGE_REPO}@"*) ;;
    *) continue ;;
  esac
  created_epoch=$(date -d "$created" +%s 2>/dev/null) || created_epoch=""
  if [ -z "$created_epoch" ]; then
    echo "  keep $id (cannot parse creation time '$created'; needs GNU date)"
    continue
  fi
  if [ $((now - created_epoch)) -le "$AGE_SECONDS" ]; then
    echo "  keep $id (newer than ${AGE_HOURS}h)"
    continue
  fi
  echo "  remove $id"
  # No -f: an image in use by any container is left alone.
  $DRY || docker rmi "$id" || true
done

if [ "$MODE" = weekly ] && [ -d "$TESTDATA_PATH" ]; then
  echo "+ test_data_* dirs older than 30 days in $TESTDATA_PATH"
  if $DRY; then
    find "$TESTDATA_PATH" -maxdepth 1 -type d -name 'test_data_*' -mtime +30 -print
  else
    find "$TESTDATA_PATH" -maxdepth 1 -type d -name 'test_data_*' -mtime +30 -print -exec rm -rf {} + || true
  fi
fi

echo "+ /tmp leftovers owned by $(id -un)"
if $DRY; then
  find /tmp -maxdepth 1 -user "$(id -u)" \( -name 'geoips*' -o -name 'pytest-of-*' \) -mtime +2 -print 2>/dev/null
else
  find /tmp -maxdepth 1 -user "$(id -u)" \( -name 'geoips*' -o -name 'pytest-of-*' \) -mtime +2 -print -exec rm -rf {} + 2>/dev/null || true
fi

echo "+ runner _temp entries older than 2 days"
for t in "$HOME"/actions-runner*/_work/_temp; do
  [ -d "$t" ] || continue
  if $DRY; then find "$t" -mindepth 1 -maxdepth 1 -mtime +2 -print
  else find "$t" -mindepth 1 -maxdepth 1 -mtime +2 -print -exec rm -rf {} + 2>/dev/null || true; fi
done

echo "=== After ($MODE) ==="; report
