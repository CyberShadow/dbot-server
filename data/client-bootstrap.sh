#!/bin/bash

# Arguments:
# 1  - Directory to do our business in
# 2  - DMD download URL (to build the client)
# 3  - Path to rdmd.exe
# 4  - dbot-client commit
# 5  - dbot-client ref containing this commit
# 6+ - dbot-client arguments

_() {
set -euo pipefail

DIR="$1"
DMD_URL="$2"
RDMD_PATH="$3"
CLIENT_COMMIT="$4"
CLIENT_REF="$5"
shift 5

mkdir -p "$DIR"
cd "$DIR"

ZIP="$(basename "$DMD_URL")"
if [[ ! -f "$ZIP" ]]
then
	rm -f "$ZIP".tmp
	wget -O "$ZIP".tmp "$DMD_URL"
	mv "$ZIP".tmp "$ZIP"
fi

DMD_DIR="${ZIP%.*}"
if [[ ! -d "$DMD_DIR" ]]
then
	rm -rf "$DMD_DIR".tmp
	mkdir "$DMD_DIR".tmp
	unzip "$ZIP" -d "$DMD_DIR".tmp
	mv "$DMD_DIR".tmp "$DMD_DIR"
fi

CLIENT_DIR=dbot-client-"$CLIENT_COMMIT"
if [[ ! -d "$CLIENT_DIR" ]]
then
	rm -rf "$CLIENT_DIR".tmp
	git clone https://github.com/CyberShadow/dbot-client "$CLIENT_DIR".tmp
	(
		cd "$CLIENT_DIR".tmp
		# TODO: Test merge with master, not actual ref
		git fetch origin "+$CLIENT_REF:"
		git checkout "$CLIENT_COMMIT"
		git submodule update --init
	)
	mv "$CLIENT_DIR".tmp "$CLIENT_DIR"
fi

RDMD_PATH=$(realpath "$RDMD_PATH")
cd "$CLIENT_DIR"
"$RDMD_PATH" client.d "$@"

}

_ "$@"

exit
