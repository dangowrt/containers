#!/bin/sh
# stage-container.sh <image> <hashfile> <stagedir> <name> <ref> <digest> <tmpfs-overlay-size> <autostart> <volspec>
# env: UCODE GEN_REGISTRATION [PREINST_IN PREINST_OUT]
set -e

image="$1"
hashfile="$2"
stage="$3"
name="$4"
ref="$5"
digest="$6"
tmpfs="$7"
autostart="$8"
volspec="$9"

volume="sha256-$(cat "$hashfile")"

rm -rf "$stage"
mkdir -p "$stage/uvol" "$stage/tmp/run/uvol/.meta/uxc"
cp "$image" "$stage/uvol/$volume"

"$UCODE" "$GEN_REGISTRATION" \
	"$stage/tmp/run/uvol/.meta/uxc/$name.json" \
	"$volspec" "$name" "$ref" "$digest" "/tmp/run/uvol/$volume" "$tmpfs" "$autostart"

# bake the pre-install/pre-upgrade reap script with the new image hash and size
if [ -n "$PREINST_IN" ] && [ -n "$PREINST_OUT" ]; then
	sed -e "s|@@NAME@@|$name|g" \
	    -e "s|@@NEWVOL@@|$volume|g" \
	    -e "s|@@NEWSIZE@@|$(wc -c < "$image")|g" \
	    "$PREINST_IN" > "$PREINST_OUT"
	chmod 0755 "$PREINST_OUT"
fi
