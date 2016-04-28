#!/bin/bash

# Arguments:
# 1 - Directory to do our business in
# 2 - DMD download URL (to build the client)
# 3 - Path to rdmd.exe
# 4 - dbot-client source shapshot zip file download URL

_() {
set -euo pipefail

get_zip() {
	URL="$1"
	ZIP="$(basename "$URL")"
	DIR="${2:-${ZIP%.*}}"
	if [[ ! -f "$ZIP" ]]
	then
		rm -f "$ZIP".tmp
		wget -O "$ZIP".tmp "$URL"
		mv "$ZIP".tmp "$ZIP"
	fi

	if [[ ! -d "$DIR" ]]
	then
		rm -rf "$DIR".tmp
		mkdir "$DIR".tmp
		unzip "$ZIP" -d "$DIR".tmp
		mv "$DIR".tmp "$DIR"
	fi
}

DIR="$1"
DMD_URL="$2"
RDMD_PATH="$3"
CLIENT_URL="$4"
shift 4

mkdir -p "$DIR"
cd "$DIR"

get_zip "$DMD_URL"

DMD_DIR="${ZIP%.*}"
if [[ ! -d "$DMD_DIR" ]]
then
	rm -rf "$DMD_DIR".tmp
	mkdir "$DMD_DIR".tmp
	unzip "$ZIP" -d "$DMD_DIR".tmp
	mv "$DMD_DIR".tmp "$DMD_DIR"
fi

ZIP="$(basename "$CLIENT_URL")"
if [[ ! -f "$ZIP" ]]
then
	rm -f "$ZIP".tmp
	wget -O "$ZIP".tmp "$CLIENT_URL"
	mv "$ZIP".tmp "$ZIP"
fi

CLIENT_DIR="${ZIP%.*}"
if [[ ! -d "$CLIENT_DIR" ]]
then
	rm -rf "$CLIENT_DIR".tmp
	mkdir "$CLIENT_DIR".tmp
	unzip "$ZIP" -d "$CLIENT_DIR".tmp
	mv "$CLIENT_DIR".tmp "$CLIENT_DIR"
fi

"$RDMD_PATH" "$CLIENT_DIR"

}

_ "$@"
