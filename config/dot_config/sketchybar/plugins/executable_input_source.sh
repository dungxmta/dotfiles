#!/bin/sh

OUT="$(osascript -l JavaScript -e 'ObjC.import("Carbon"); const s=$.TISCopyCurrentKeyboardInputSource(); const g=p=>ObjC.castRefToObject($.TISGetInputSourceProperty(s,p)).js; g($.kTISPropertyInputSourceID)+"|"+g($.kTISPropertyLocalizedName)' 2>/dev/null)" || exit 0
[ -n "$OUT" ] || exit 0

ID=${OUT%%|*}
NAME_FULL=${OUT#*|}

case "$ID" in
  com.apple.keylayout.UnicodeHexInput) LABEL="U+" ;;
  com.apple.inputmethod.VietnameseIM*) LABEL="VI" ;;
  com.apple.keylayout.Australian) LABEL="AU" ;;
  com.apple.keylayout.ABC) LABEL="ABC" ;;
  com.apple.keylayout.US) LABEL="US" ;;
  *) LABEL="$NAME_FULL" ;;
esac

sketchybar --set "$NAME" label="$LABEL"
