#!/usr/bin/env bash
# Build a signed Tizen TPK for distribution.
#
# Local dev usage (uses your active Tizen Studio profile):
#   ./tizen/scripts/build_tizen.sh
#
# CI usage (set these env vars from secrets before running):
#   TIZEN_AUTHOR_CERT_BASE64    - base64-encoded author .p12 certificate
#   TIZEN_AUTHOR_CERT_PASSWORD  - author certificate password
#   TIZEN_DIST_CERT_BASE64      - base64-encoded distributor .p12 certificate
#   TIZEN_DIST_CERT_PASSWORD    - distributor certificate password
#
# TIZEN_BUILD=true is always injected so the compiled TPK has the correct
# platform branches regardless of how flutter-tizen was invoked.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_NAME="tizen_signing"

MODE="--release"
for arg in "$@"; do
	if [[ "$arg" == "--debug" ]]; then
		MODE="--debug"
		shift
		break
	fi
done

# If CI credentials are present, write the certificate profile so flutter-tizen
# can pick it up. Mirrors the Android keystore / macOS certificate pattern in
# .github/workflows/build.yml.
if [[ -n "${TIZEN_AUTHOR_CERT_BASE64:-}" ]]; then
	CERT_DIR="$HOME/.tizen-studio/keystore/signing/$PROFILE_NAME"
	mkdir -p "$CERT_DIR"

	echo "$TIZEN_AUTHOR_CERT_BASE64" | base64 --decode >"$CERT_DIR/author.p12"
	echo "$TIZEN_DIST_CERT_BASE64" | base64 --decode >"$CERT_DIR/distributor.p12"

	PROFILES_DIR="$HOME/.tizen-studio-data/profile"
	mkdir -p "$PROFILES_DIR"

	# Write the profile XML that Tizen Studio / flutter-tizen reads.
	# Passwords are stored in plain-text here; the file is 0600 and ephemeral in CI.
	cat >"$PROFILES_DIR/profiles.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<profiles version="3.1">
  <profile name="$PROFILE_NAME">
    <profileitem ca="" distributor="0" key="$CERT_DIR/author.p12" password="${TIZEN_AUTHOR_CERT_PASSWORD}" rootca=""/>
    <profileitem ca="" distributor="2" key="$CERT_DIR/distributor.p12" password="${TIZEN_DIST_CERT_PASSWORD}" rootca=""/>
  </profile>
</profiles>
XML
	chmod 0600 "$PROFILES_DIR/profiles.xml"
fi

flutter-tizen build tpk \
	$MODE \
	--dart-define=TIZEN_BUILD=true \
	"$@"
