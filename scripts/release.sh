#!/bin/sh
set -eu

# Cut a release in one command:
#   scripts/release.sh <version>          e.g.  scripts/release.sh 0.2.0
#
# It bumps the app version, commits "Release vX.Y.Z", tags it, pushes, and
# creates the GitHub release (notes from the matching CHANGELOG.md section, or
# auto-generated). Requires a clean working tree and the gh CLI.
# Then it waits for the Release workflow to attach the build; if no GitHub
# macOS runner picks it up within RELEASE_WAIT_MIN minutes (default 20), it
# builds locally, attaches that and verifies the uploaded checksum.
#
# Tip: add the new version's section to CHANGELOG.md *before* running this.

VERSION="${1:-}"
case "${VERSION}" in
  "")  echo "Usage: scripts/release.sh <version>   (e.g. 0.2.0)"; exit 1 ;;
  v*)  echo "Pass the version without a leading 'v' (e.g. 0.2.0, not v0.2.0)"; exit 1 ;;
esac
echo "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "Version must be MAJOR.MINOR.PATCH (e.g. 0.2.0)"; exit 1; }

cd "$(dirname "$0")/.."

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is required: https://cli.github.com"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean — commit or stash changes first."; exit 1; }

TAG="v${VERSION}"

# Always target the repo `origin` points at (this fork). Without -R, gh picks
# the fork's *parent* as the default repo and tries to release there.
REPO="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "Tag ${TAG} already exists."; exit 1
fi

# Bump CFBundleShortVersionString in the installer's Info.plist template.
python3 - "${VERSION}" <<'PY'
import re, sys
v = sys.argv[1]
path = "scripts/install.sh"
src = open(path).read()
out, n = re.subn(
    r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)',
    r'\g<1>' + v + r'\g<2>', src)
if n == 0:
    sys.exit("Could not find CFBundleShortVersionString in scripts/install.sh")
open(path, "w").write(out)
PY

git add scripts/install.sh
if git diff --cached --quiet; then
  printf '%s\n' "scripts/install.sh already at ${VERSION}; tagging the current commit."
else
  git commit -m "Release ${TAG}"
fi
git tag "${TAG}"
git push origin HEAD
git push origin "${TAG}"

# Release notes: the matching CHANGELOG section if present, else auto-generated.
NOTES="$(awk -v v="${VERSION}" '
  $0 ~ ("^## \\[" v "\\]") { grab = 1; next }
  grab && /^## /           { exit }
  grab                     { print }
' CHANGELOG.md 2>/dev/null || true)"

if [ -n "$(printf '%s' "${NOTES}" | tr -d '[:space:]')" ]; then
  TMP_NOTES="$(mktemp)"
  printf '%s\n' "${NOTES}" > "${TMP_NOTES}"
  gh release create "${TAG}" -R "${REPO}" --title "${TAG}" --notes-file "${TMP_NOTES}"
  rm -f "${TMP_NOTES}"
else
  gh release create "${TAG}" -R "${REPO}" --title "${TAG}" --generate-notes
fi

echo "Released ${TAG}"

# ---------------------------------------------------------------------------
# Build assets. The Release workflow builds and attaches them on a GitHub
# macOS runner; those are sometimes scarce and a job can sit in the queue
# for a long time. Wait up to RELEASE_WAIT_MIN minutes (default 20; 0 builds
# locally right away), then build the same tagged commit here, attach it and
# check the uploaded copy. The app isn't signed, so a local build is
# equivalent to the CI one.
WAIT_MIN="${RELEASE_WAIT_MIN:-20}"

has_assets() {
  gh release view "${TAG}" -R "${REPO}" --json assets -q '.assets[].name' 2>/dev/null \
    | grep -qx 'ClaudexBar.zip.sha256'
}

release_run() { # id and status of the Release workflow run for this tag
  gh run list -R "${REPO}" --workflow release.yml --branch "${TAG}" --limit 1 \
    --json databaseId,status,conclusion -q '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null || true
}

deadline=$(( $(date +%s) + WAIT_MIN * 60 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  if has_assets; then
    echo "Assets attached by the Release workflow."
    exit 0
  fi
  set -- $(release_run)
  if [ "${2:-}" = "completed" ] && [ "${3:-}" != "success" ]; then
    echo "Release workflow finished with '${3:-?}' — building locally."
    break
  fi
  printf 'Waiting for the Release workflow (%s)…\n' "${2:-not started}"
  sleep 30
done
has_assets && { echo "Assets attached by the Release workflow."; exit 0; }

# Stop a still-queued CI build so it can't replace the local assets later.
set -- $(release_run)
if [ -n "${1:-}" ] && [ "${2:-}" != "completed" ]; then
  gh run cancel "$1" -R "${REPO}" >/dev/null 2>&1 || true
  echo "Cancelled the waiting Release workflow run $1."
fi

echo "Building ${TAG} locally…"
rm -rf dist
VERSION="${VERSION}" sh scripts/build-app.sh dist
( cd dist \
  && ditto -c -k --keepParent ClaudexBar.app ClaudexBar.zip \
  && shasum -a 256 ClaudexBar.zip > ClaudexBar.zip.sha256 )

uploaded=""
for attempt in 1 2 3 4 5; do
  if gh release upload "${TAG}" -R "${REPO}" dist/ClaudexBar.zip dist/ClaudexBar.zip.sha256 --clobber; then
    uploaded=1; break
  fi
  echo "Upload failed (attempt ${attempt}), retrying…"; sleep 10
done
[ -n "${uploaded}" ] || { echo "Could not upload the assets."; exit 1; }

# Check what users will download, not just what was sent.
CHECK="$(mktemp -d)"
gh release download "${TAG}" -R "${REPO}" -D "${CHECK}" -p 'ClaudexBar.zip*' --clobber
EXPECTED="$(awk '{print $1}' "${CHECK}/ClaudexBar.zip.sha256")"
ACTUAL="$(shasum -a 256 "${CHECK}/ClaudexBar.zip" | awk '{print $1}')"
rm -rf "${CHECK}"
[ "${EXPECTED}" = "${ACTUAL}" ] || { echo "Uploaded assets don't match (${EXPECTED} vs ${ACTUAL})."; exit 1; }
echo "Assets built locally and attached; checksum verified (${ACTUAL})."
