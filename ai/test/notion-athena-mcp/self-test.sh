#!/usr/bin/env bash
# Self-test for ai/bin/notion-athena-mcp's Notion-Version shim (DND-1449).
#
# Bug: @notionhq/notion-mcp-server 2.5.x sends no Notion-Version on most
# operations, so create-a-comment fails 400 missing_version. The shim
# (ai/lib/notion-version-shim.cjs), preloaded by the wrapper, adds the default.
#
# NO NETWORK: a local listener on 127.0.0.1 stands in for Notion; the shim's
# host match is pointed at 127.0.0.1 through its test seam. `npx` is a PATH
# stub, so the wrapper's real NODE_OPTIONS preload is what is under test.
#
# Run: bash ai/test/notion-athena-mcp/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${AI_DIR}/bin/notion-athena-mcp"
SHIM="${AI_DIR}/lib/notion-version-shim.cjs"
PROBE="${HERE}/probe.cjs"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
expect() { # name want got
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "want '$2' got '$3'"; fi
}

command -v node >/dev/null 2>&1 || { echo "FAIL: node not found"; echo "Fix: install node (asdf) so the shim can be tested"; exit 1; }

export NOTION_VERSION_SHIM_EXTRA_HOST=127.0.0.1

# Without the preload the request carries no version: the defect.
expect "unfixed: no preload sends no Notion-Version" "<none>" "$(node "${PROBE}" 127.0.0.1)"
# With it, the default is added.
expect "shim adds the default version when none is set" "2025-09-03" \
  "$(NODE_OPTIONS="--require ${SHIM}" node "${PROBE}" 127.0.0.1)"
# A version the server set (markdown tools) is kept.
expect "shim keeps a version the server set" "2026-03-11" \
  "$(NODE_OPTIONS="--require ${SHIM}" node "${PROBE}" 127.0.0.1 2026-03-11)"
# A request to another host is untouched.
expect "shim leaves other hosts alone" "<none>" \
  "$(NODE_OPTIONS="--require ${SHIM}" node "${PROBE}" localhost)"

# The wrapper wires the preload: a stub npx runs the probe under the wrapper's env.
mkdir -p "${TMP}/stubbin"
cat > "${TMP}/stubbin/npx" <<STUB
#!/bin/sh
[ "\$1" = "-v" ] && { echo 10.0.0; exit 0; }
printf '%s\\n' "\$@" > "${TMP}/npx-args"
exec node "${PROBE}" 127.0.0.1
STUB
chmod +x "${TMP}/stubbin/npx"
echo "placeholder" > "${TMP}/token"
out="$(NOTION_ATHENA_TOKEN_FILE="${TMP}/token" PATH="${TMP}/stubbin:${PATH}" "${WRAPPER}" 2>&1)"
expect "wrapper preloads the shim for the server process" "2025-09-03" "${out}"

# DND-1543: the package spec npx receives carries an exact x.y.z version.
spec="$(grep '^@notionhq/notion-mcp-server' "${TMP}/npx-args" 2>/dev/null || true)"
if printf '%s' "${spec}" | grep -Eq '^@notionhq/notion-mcp-server@[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "npx package spec is pinned to an exact version"
else
  bad "npx package spec is pinned to an exact version" "got '${spec}'; Fix: set NOTION_MCP_SERVER_VERSION in ai/bin/notion-athena-mcp to an exact x.y.z"
fi

# A wrapper copy with no shim beside it refuses, with a Fix:.
mkdir -p "${TMP}/copy/bin"; cp "${WRAPPER}" "${TMP}/copy/bin/notion-athena-mcp"
out="$(NOTION_ATHENA_TOKEN_FILE="${TMP}/token" PATH="${TMP}/stubbin:${PATH}" "${TMP}/copy/bin/notion-athena-mcp" 2>&1)"; rc=$?
expect "missing shim exits 1" "1" "${rc}"
case "${out}" in *"Fix: restore ai/lib/notion-version-shim.cjs"*) ok "missing shim names the Fix";; *) bad "missing shim names the Fix" "${out}";; esac

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
