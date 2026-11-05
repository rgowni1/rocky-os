#!/bin/bash
# Send an iMessage via the local Messages app. Works headlessly (no MCP needed).
#
#   echo "text" | ./imessage.sh +16465057208
#   ./imessage.sh +16465057208 "text"
#
# Requires Automation permission for whatever runs this (Terminal / launchd).
# Messages.app does not need to be running first.
set -euo pipefail

RECIPIENT="${1:-}"
[ -n "$RECIPIENT" ] || { echo "usage: $0 <recipient> [message]   (or pipe message on stdin)" >&2; exit 1; }

if [ $# -ge 2 ]; then
  MESSAGE="$2"
else
  MESSAGE="$(cat)"
fi
[ -n "$MESSAGE" ] || { echo "refusing to send an empty message" >&2; exit 1; }

# Pass text via argv so quotes/newlines/emoji survive without escaping into the script body.
osascript - "$RECIPIENT" "$MESSAGE" <<'APPLESCRIPT'
on run argv
  set theRecipient to item 1 of argv
  set theMessage to item 2 of argv
  tell application "Messages"
    set theService to 1st service whose service type = iMessage
    set theBuddy to buddy theRecipient of theService
    send theMessage to theBuddy
  end tell
end run
APPLESCRIPT

echo "sent to $RECIPIENT (${#MESSAGE} chars)"
