#!/bin/bash
# Two independent fixture processes must not share the same live listener port.
set -euo pipefail
ulimit -c 0
BINARY=$1
TEMP=$(mktemp -d)
FIRST=
SECOND=
cleanup() {
  if [[ -n "${FIRST}" ]]; then kill "${FIRST}" 2>/dev/null || true; wait "${FIRST}" 2>/dev/null || true; fi
  if [[ -n "${SECOND}" ]]; then kill "${SECOND}" 2>/dev/null || true; wait "${SECOND}" 2>/dev/null || true; fi
  rm -rf "${TEMP}"
}
trap cleanup EXIT
mkdir "${TEMP}/first" "${TEMP}/second"
PORT=$(python3 - <<'PYTHON'
import socket
with socket.socket() as candidate:
    candidate.bind(('127.0.0.1', 0))
    print(candidate.getsockname()[1])
PYTHON
)
"${BINARY}" https://bridge.example.test "${TEMP}/first" "${PORT}" >"${TEMP}/first.log" 2>&1 &
FIRST=$!
for _ in $(seq 1 100); do
  [[ -f "${TEMP}/first/ready" ]] && break
  kill -0 "${FIRST}" 2>/dev/null || { cat "${TEMP}/first.log"; exit 1; }
  sleep 0.1
done
[[ -f "${TEMP}/first/ready" ]] || { echo 'First fixture listener did not become ready'; exit 1; }
"${BINARY}" https://bridge.example.test "${TEMP}/second" "${PORT}" >"${TEMP}/second.log" 2>&1 &
SECOND=$!
for _ in $(seq 1 100); do
  if ! kill -0 "${SECOND}" 2>/dev/null; then break; fi
  [[ ! -f "${TEMP}/second/ready" ]] || { echo 'Second process bound the active port'; exit 1; }
  sleep 0.1
done
if kill -0 "${SECOND}" 2>/dev/null; then echo 'Second process did not refuse the live port'; exit 1; fi
status=0
wait "${SECOND}" || status=$?
SECOND=
[[ "${status}" -ne 0 ]] || { echo 'Second process unexpectedly succeeded'; exit 1; }
[[ ! -f "${TEMP}/second/ready" ]] || { echo 'Second process reached readiness'; exit 1; }
grep -Fq 'Address already in use' "${TEMP}/second.log" || { cat "${TEMP}/second.log"; exit 1; }
curl --fail --silent --show-error --max-time 2 -H 'Host: bridge.example.test' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:${PORT}/" >"${TEMP}/page"
grep -Fq 'Pair this browser' "${TEMP}/page"
echo 'LISTENER PROCESS REGRESSION: second independent process refused; first listener still serves.'
