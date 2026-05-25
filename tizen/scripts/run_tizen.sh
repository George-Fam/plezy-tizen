#!/usr/bin/env bash
# Run the app on a connected Tizen device for development.
#
# Usage:
#   ./tizen/scripts/run_tizen.sh -d <device-ip>           # release mode
#   ./tizen/scripts/run_tizen.sh -d <device-ip> --debug   # debug mode
#
# All extra arguments are forwarded to flutter-tizen run.

set -euo pipefail

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
