#!/bin/sh

# VimMac mode indicator.
# VimMac posts the distributed notification com.dungx.VimMac.status with
# userInfo {"mode": "<INS|NOR|VIS|VLN|OFF|AX?>"} on every change ("" = VimMac quit).
# On (re)load we ask a running VimMac to re-post via com.dungx.VimMac.statusRequest.

if [ "$SENDER" != "vimmac_status" ]; then
  if pgrep -xq VimMac; then
    # $() is ObjC nil; JS null does not bridge here and the post is silently dropped.
    osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.dungx.VimMac.statusRequest", $(), $(), true)' >/dev/null 2>&1
  else
    sketchybar --set "$NAME" drawing=off
  fi
  exit 0
fi

MODE=$(printf '%s' "$INFO" | sed -n 's/.*"mode" *: *"\([^"]*\)".*/\1/p')

case "$MODE" in
"")
  sketchybar --set "$NAME" drawing=off
  exit 0
  ;;
NOR)
  LABEL="NORMAL"
  COLOR=0xff7aa2f7
  ;; # blue
VIS)
  LABEL="VISUAL"
  COLOR=0xffbb9af7
  ;; # purple
VLN)
  LABEL="V-LINE"
  COLOR=0xffbb9af7
  ;; # purple
INS)
  LABEL="INSERT"
  COLOR=0xff9ece6a
  ;; # green
OFF)
  LABEL="Off"
  COLOR=0xff7f849c
  ;; # grey
*)
  LABEL="$MODE"
  COLOR=0xff7f849c
  ;; # grey: AX?
esac

sketchybar --set "$NAME" drawing=on label="$LABEL" label.color="$COLOR"
