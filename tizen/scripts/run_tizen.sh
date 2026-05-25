#!/usr/bin/env bash
# Run the app on a connected Tizen device for development.
#
# Usage:
#   ./tizen/scripts/run_tizen.sh -d <device-ip>           # release mode
#   ./tizen/scripts/run_tizen.sh -d <device-ip> --debug   # debug mode
#
# All extra arguments are forwarded to flutter-tizen run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Sync tizen-manifest.xml version from pubspec.yaml (e.g. "2.2.0+100" -> "2.2.0").
PUBSPEC_VERSION="$(grep '^version:' "$REPO_ROOT/pubspec.yaml" | sed 's/version:[[:space:]]*//' | sed 's/+.*//' | tr -d '[:space:]')"
if [[ -n "$PUBSPEC_VERSION" ]]; then
	sed -i "s/\(<manifest[^>]* version=\"\)[^\"]*\"/\1$PUBSPEC_VERSION\"/" "$REPO_ROOT/tizen/tizen-manifest.xml"
fi

MODE="--release"
EXTRA_ARGS=()
for arg in "$@"; do
	if [[ "$arg" == "--debug" ]]; then
		MODE="--debug"
	else
		EXTRA_ARGS+=("$arg")
	fi
done

flutter-tizen run \
	$MODE \
	--dart-define=TIZEN_BUILD=true \
	--extra-front-end-options=--enable-experiment=private-named-parameters \
	"${EXTRA_ARGS[@]}"
