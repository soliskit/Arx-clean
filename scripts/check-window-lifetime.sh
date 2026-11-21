#!/bin/bash
# Hosted Mac fixture-only lifecycle proof. Never connects to an EventKit store.
set -euo pipefail
[[ "${CI:-}" == true && "${ARX_FIXTURE_DISPLAY_READY:-}" == 1 ]] || { echo "Window lifetime proof is restricted to the CI fixture display."; exit 1; }
APP=$1
PID=$2
ps -p "${PID}" -o args= | grep -Fq -- '--bridge-fixtures'
REOPENED_PID=
cleanup() { if [[ -n "${REOPENED_PID}" ]]; then kill "${REOPENED_PID}" 2>/dev/null || true; fi; }
trap cleanup EXIT
# An existing listener would make the fixture test unsafe or inconclusive.
if lsof -nP -iTCP:18769 -sTCP:LISTEN; then echo "Fixture port already occupied"; exit 1; fi
control() {
  osascript - "$@" <<'APPLESCRIPT'
on attr(node, key)
  try
    tell application "System Events" to return value of attribute key of node
  on error
    return missing value
  end try
end attr
on run argv
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    set nodes to entire contents of window 1
  end tell
  set target to missing value
  set countMatches to 0
  repeat with nodeRef in nodes
    set node to contents of nodeRef
    if item 1 of argv is "field" then
      set matches to (my attr(node, "AXRole") is "AXTextField" and (my attr(node, "AXPlaceholderValue") is item 2 of argv or my attr(node, "AXValue") is item 2 of argv))
    else
      set matches to (my attr(node, "AXRole") is "AXButton" and my attr(node, "AXIdentifier") is item 2 of argv)
    end if
    if matches then
      set target to node
      set countMatches to countMatches + 1
    end if
  end repeat
  if countMatches is not 1 then error "Expected one fixture control: " & item 2 of argv & ", found " & countMatches
  if item 1 of argv is "field" then
    tell application "System Events"
      set value of attribute "AXFocused" of target to true
      keystroke "a" using command down
      keystroke item 3 of argv
      key code 48
    end tell
  else if item 1 of argv is "enabled" then
    if (my attr(target, "AXEnabled") as text) is not item 3 of argv then error "Unexpected enabled state: " & item 2 of argv
  else
    if my attr(target, "AXEnabled") is not true then error "Disabled fixture button: " & item 2 of argv
    tell application "System Events" to perform action "AXPress" of target
  end if
end run
APPLESCRIPT
}
control field 'Exact remote HTTPS origin' https://bridge.example.test
control field 8765 18769
control press bridge-start
ready=false
for _ in $(seq 1 50); do
  if curl --fail --silent --show-error --max-time 1 -H 'Host: bridge.example.test' -H 'X-Forwarded-Proto: https' http://127.0.0.1:18769/ > fixture-lifetime-page.html 2>fixture-lifetime-curl.log; then ready=true; break; fi
  sleep 0.2
done
[[ "${ready}" == true ]] || { cat fixture-lifetime-curl.log; echo "Fixture listener never became ready"; exit 1; }
grep -Fq 'Pair this browser' fixture-lifetime-page.html
# A singleton must not create a second independent bridge on the usual New shortcut.
osascript -e 'tell application "System Events" to tell process "Arx" to keystroke "n" using command down'
sleep 1
windows=$(osascript -e 'tell application "System Events" to tell process "Arx" to count windows')
[[ "${windows}" == 1 ]] || { echo "New created another window"; exit 1; }
osascript -e 'tell application "System Events" to tell process "Arx" to keystroke "w" using command down'
for _ in $(seq 1 50); do
  if ! kill -0 "${PID}" 2>/dev/null; then break; fi
  sleep 0.2
done
if kill -0 "${PID}" 2>/dev/null; then echo "Fixture process survived closing its sole window"; exit 1; fi
status=0
curl --silent --show-error --max-time 2 http://127.0.0.1:18769/ > fixture-after-close.txt 2>fixture-after-close.log || status=$?
[[ "${status}" == 7 ]] || { echo "Expected connection refused after close, got curl ${status}"; cat fixture-after-close.log; exit 1; }
"${APP}/Contents/MacOS/Arx" --bridge-fixtures > fixture-reopen.log 2>&1 &
REOPENED_PID=$!
windows=0
for _ in $(seq 1 50); do
  windows=$(osascript -e 'tell application "System Events" to tell process "Arx" to count windows' 2>/dev/null || true)
  [[ "${windows}" == 1 ]] && break
  sleep 0.2
done
[[ "${windows}" == 1 ]] || { echo "Fixture did not reopen with one window"; exit 1; }
control enabled bridge-start true
control enabled bridge-stop false
status=0
curl --silent --show-error --max-time 2 http://127.0.0.1:18769/ > fixture-after-reopen.txt 2>fixture-after-reopen.log || status=$?
[[ "${status}" == 7 ]] || { echo "Reopening unexpectedly restored a listener"; exit 1; }
echo 'Fixture lifetime passed: one window; listener started; close exited/refused; reopen stopped.'
