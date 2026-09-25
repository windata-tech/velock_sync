#!/bin/bash
set -eu
umask 077
HERE="$(cd "$(dirname "$0")" && pwd -P)"
if [ "$#" -lt 2 ]; then
  echo "Usage: $0 INPUT.mp4 NEW_OUTPUT_DIR [step=1] [minDwell=6] [start=0] [end=duration]" >&2
  exit 2
fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/velock-video-qc.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
command -v swiftc >/dev/null # no ffmpeg dependency
swiftc "$HERE/video_qc.swift" -o "$BUILD/video-qc"
"$BUILD/video-qc" --self-test
"$BUILD/video-qc" "$@"
