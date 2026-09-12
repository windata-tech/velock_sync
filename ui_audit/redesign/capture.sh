#!/bin/zsh
# usage: capture.sh NAME
DIR="/Users/parcool/AndroidStudioProjects/velock_sync/ui_audit/redesign"
DEV="EA9A8C79-0ED3-4E97-8D93-B0EADC70631B"
NAME="$1"
xcrun simctl io "$DEV" screenshot --type=png "$DIR/$NAME.png" >/dev/null 2>&1
sips -Z 1360 "$DIR/$NAME.png" --out "$DIR/$NAME-view.png" >/dev/null 2>&1
echo "$DIR/$NAME-view.png"
