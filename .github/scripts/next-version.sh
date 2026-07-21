#!/usr/bin/env bash
# Compute the next Android versionCode / versionName from existing
# git tags of the form `vN.M.K`. Echoes three lines:
#   tag=<tag-name>
#   version_name=<N.M.K>
#   version_code=<N*10000 + M*100 + K>
#
# Reads tags with `git tag -l "v*"` so it doesn't require a remote fetch.
# Designed to be called from a GitHub Actions step after checkout.
#
# Examples:
#   no tags yet     → tag=v0.1.0 version_name=0.1.0 version_code=100
#   v0.1.0          → tag=v0.1.1 version_name=0.1.1 version_code=101
#   v0.1.9          → tag=v0.1.10 version_name=0.1.10 version_code=110
#   v0.2.5          → tag=v0.2.6 version_name=0.2.6 version_code=206
#   v0.2.99         → tag=v0.2.100 version_name=0.2.100 version_code=2100
#   v9.9.99         → tag=v9.9.100 version_name=9.9.100 version_code=99900
#   v1.0.0          → tag=v1.0.1 version_name=1.0.1 version_code=10001
set -euo pipefail

# Pull both remote and local tags. CI runners do a shallow clone
# by default; --tags ensures we see remote tags too.
git fetch --tags --force --prune >/dev/null 2>&1 || true

# Read all vN.M.K tags. The regex requires three dot-separated
# integers — anything else is ignored, so a stray `v0.1` doesn't
# confuse the sort.
mapfile -t TAGS < <(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V)

if [[ ${#TAGS[@]} -eq 0 ]]; then
  echo "tag=v0.1.0"
  echo "version_name=0.1.0"
  echo "version_code=100"
  exit 0
fi

# Highest tag is the last entry after sort -V.
HIGHEST="${TAGS[-1]}"

# Strip the leading 'v'.
NUM="${HIGHEST#v}"

# Split into N / M / K. Using IFS=. and reading into an array handles
# any number of digits cleanly without regex backrefs.
IFS='.' read -r N M K <<<"$NUM"

# Defensive: if any component isn't a number, fall back to v0.1.0 so the
# build doesn't silently produce a malformed version.
if ! [[ "$N" =~ ^[0-9]+$ && "$M" =~ ^[0-9]+$ && "$K" =~ ^[0-9]+$ ]]; then
  echo "tag=v0.1.0"
  echo "version_name=0.1.0"
  echo "version_code=100"
  exit 0
fi

K=$((K + 1))

NEW_TAG="v${N}.${M}.${K}"
VERSION_NAME="${N}.${M}.${K}"
VERSION_CODE=$((N * 10000 + M * 100 + K))

echo "tag=${NEW_TAG}"
echo "version_name=${VERSION_NAME}"
echo "version_code=${VERSION_CODE}"