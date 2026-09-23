#!/usr/bin/env bash
# Discovered self-test for scripts/add-athena-mcp and the DND-295 bearer-export
# block in scripts/athena.
#
# Covers:
#   * add-athena-mcp --help: stdout only, exit 0, no side effects (repo rule).
#   * add-athena-mcp --dry-run URL derivation: from a stub inbox config's
#     server_url; a --url override; and the failed-lookup case — an absent or
#     server_url-less config falls back to the default URL, observably.
#   * scripts/athena bearer export: already-set is kept; a present config's
#     token is read and exported; a present-but-tokenless config HARD-FAILS
#     loudly (exit 1 + Fix:); an ABSENT config is environment-safe (launch
#     proceeds, no fail) so an unrelated `claude` launch is never broken.
#
# No real `claude` CLI or real inbox config is touched: HOME is redirected to a
# temp tree and `claude` is stubbed on PATH.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
add_mcp="${here}/../../add-athena-mcp"
launcher="${here}/../../athena"
[ -x "${add_mcp}" ] || { echo "FAIL not executable: ${add_mcp}"; exit 1; }
[ -x "${launcher}" ] || { echo "FAIL not executable: ${launcher}"; exit 1; }

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want [$2] got [$3])"; fi
}
assert_contains() { # desc haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing [$3])" ;; esac
}

tmproot="$(mktemp -d)"
trap 'rm -rf "${tmproot}"' EXIT

# A HOME with a stubbed `claude` on PATH and a writable config location.
make_home() { # token server_url  (empty token => no .token key)
  local h; h="$(mktemp -d "${tmproot}/home.XXXXXX")"
  mkdir -p "${h}/.config/athena-inbox-client" "${h}/bin"
  printf '#!/usr/bin/env bash\necho "CLAUDE_LAUNCHED bearer=[${ATHENA_MCP_BEARER:-}]"\n' > "${h}/bin/claude"
  chmod +x "${h}/bin/claude"
  # scripts/athena execs "${HOME}/.local/bin/claude"; provide it there too.
  mkdir -p "${h}/.local/bin"
  cp "${h}/bin/claude" "${h}/.local/bin/claude"
  printf '%s' "${h}"
}
write_config() { # home token server_url
  local cfg="$1/.config/athena-inbox-client/config.json"
  if [ -n "$2" ]; then
    printf '{"token":"%s","server_url":"%s"}' "$2" "$3" > "${cfg}"
  else
    printf '{"server_url":"%s"}' "$3" > "${cfg}"
  fi
}

# ── add-athena-mcp --help: stdout only, exit 0 ──────────────────────────────
help_err="${tmproot}/help.err"
if out="$("${add_mcp}" --help 2>"${help_err}")"; then
  assert_contains "help mentions the tool" "${out}" "add-athena-mcp"
  assert_eq "help writes nothing to stderr" "0" "$(wc -c < "${help_err}" | tr -d ' ')"
else
  fail "help exited non-zero"
fi

# ── --dry-run URL derivation from server_url ────────────────────────────────
h="$(make_home)"; write_config "${h}" "tok-xyz" "wss://mcp.example.test/machine/websocket?vsn=2.0.0"
out="$(HOME="${h}" "${add_mcp}" --dry-run 2>&1)"
assert_contains "dry-run derives https URL from server_url host" "${out}" "https://mcp.example.test/mcp"
assert_contains "dry-run header references the env var, not a token" "${out}" 'Bearer ${ATHENA_MCP_BEARER}'
case "${out}" in *tok-xyz*) fail "dry-run leaked the token" ;; *) pass "dry-run does not leak the token" ;; esac

# ── --url override wins ─────────────────────────────────────────────────────
out="$(HOME="${h}" "${add_mcp}" --dry-run --url https://override.test/mcp 2>&1)"
assert_contains "--url override wins" "${out}" "https://override.test/mcp"

# ── failed-lookup: no server_url => default URL (not empty/garbage) ──────────
h2="$(make_home)"; write_config "${h2}" "tok-2" ""
out="$(HOME="${h2}" "${add_mcp}" --dry-run 2>&1)"
assert_contains "no server_url falls back to default URL" "${out}" "https://athena.cjpoll.me/mcp"

# ── failed-lookup: absent config => default URL ─────────────────────────────
h3="$(mktemp -d "${tmproot}/home.XXXXXX")"
out="$(HOME="${h3}" "${add_mcp}" --dry-run 2>&1)"
assert_contains "absent config falls back to default URL" "${out}" "https://athena.cjpoll.me/mcp"

# ── launcher: an already-set bearer is kept and never re-read ───────────────
# No config in this home; the already-set value must win regardless.
h_preset="$(make_home)"
out="$(HOME="${h_preset}" ATHENA_MCP_BEARER="preset-value" "${launcher}" --x 2>&1 || true)"
assert_contains "launcher keeps an already-set bearer" "${out}" "bearer=[preset-value]"

# ── launcher: present config's token is read and exported ───────────────────
h4="$(make_home)"; write_config "${h4}" "tok-live" "wss://x.test/ws"
out="$(HOME="${h4}" bash -c 'unset ATHENA_MCP_BEARER; exec "$0" --x' "${launcher}" 2>&1 || true)"
assert_contains "launcher exports the config token" "${out}" "bearer=[tok-live]"

# ── launcher: present-but-tokenless config HARD-FAILS with a Fix: ───────────
h5="$(make_home)"; write_config "${h5}" "" "wss://x.test/ws"
set +e
out="$(HOME="${h5}" bash -c 'unset ATHENA_MCP_BEARER; exec "$0" --x' "${launcher}" 2>&1)"; rc=$?
set -e
assert_eq "tokenless config exits non-zero" "1" "${rc}"
assert_contains "tokenless config prints a Fix:" "${out}" "Fix:"
case "${out}" in *CLAUDE_LAUNCHED*) fail "claude launched despite a tokenless config" ;; *) pass "claude not launched on a tokenless config" ;; esac

# ── launcher: PRESENT-but-unreadable config HARD-FAILS (not silent skip) ────
# A wrong-perms config is the Athena environment with a broken required input;
# it must NOT read as "absent" and take the env-safe skip. Skipped as root
# (root can read a 000 file, so the condition cannot be reproduced there).
if [ "$(id -u)" -ne 0 ]; then
  h_unread="$(make_home)"; write_config "${h_unread}" "tok-nr" "wss://x.test/ws"
  chmod 000 "${h_unread}/.config/athena-inbox-client/config.json"
  set +e
  out="$(HOME="${h_unread}" bash -c 'unset ATHENA_MCP_BEARER; exec "$0" --x' "${launcher}" 2>&1)"; rc=$?
  set -e
  chmod 600 "${h_unread}/.config/athena-inbox-client/config.json" 2>/dev/null || true
  assert_eq "unreadable-present config exits non-zero" "1" "${rc}"
  assert_contains "unreadable-present config prints a Fix:" "${out}" "Fix:"
  case "${out}" in *CLAUDE_LAUNCHED*) fail "claude launched despite an unreadable config" ;; *) pass "claude not launched on an unreadable config" ;; esac
else
  pass "unreadable-present config (skipped as root)"
fi

# ── launcher: present config but jq missing HARD-FAILS with a Fix: ──────────
# Minimal PATH with only bash+env (so the shebang still resolves) but NO jq;
# the launcher uses only builtins until it hard-fails on the missing jq.
h_nojq="$(make_home)"; write_config "${h_nojq}" "tok-j" "wss://x.test/ws"
minbin="$(mktemp -d "${tmproot}/minbin.XXXXXX")"
ln -s "$(command -v bash)" "${minbin}/bash"
ln -s "$(command -v env)" "${minbin}/env"
set +e
out="$(env -i HOME="${h_nojq}" PATH="${minbin}" "${launcher}" --x 2>&1)"; rc=$?
set -e
assert_eq "jq-missing exits non-zero" "1" "${rc}"
assert_contains "jq-missing prints a Fix:" "${out}" "Fix:"

# ── launcher: ABSENT config is environment-safe (launch proceeds) ───────────
h6="$(mktemp -d "${tmproot}/home.XXXXXX")"; mkdir -p "${h6}/.local/bin"
printf '#!/usr/bin/env bash\necho "CLAUDE_LAUNCHED bearer=[${ATHENA_MCP_BEARER:-}]"\n' > "${h6}/.local/bin/claude"
chmod +x "${h6}/.local/bin/claude"
set +e
out="$(HOME="${h6}" bash -c 'unset ATHENA_MCP_BEARER; exec "$0" --x' "${launcher}" 2>&1)"; rc=$?
set -e
assert_eq "absent config launches claude (exit 0)" "0" "${rc}"
assert_contains "absent config does not break the launch" "${out}" "CLAUDE_LAUNCHED"

# ── add-athena-mcp APPLY path (non-dry-run) via a stub `claude` ─────────────
# Stub records `mcp add` argv; all subcommands succeed. Run from a clean temp
# cwd (no .git) so the worktree warning does not fire.
stub_claude_bin() { # -> prints a bin dir containing a recording `claude`
  local b; b="$(mktemp -d "${tmproot}/stub.XXXXXX")"
  cat > "${b}/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "add" ]; then
  printf '%s\n' "$*" >> "${CLAUDE_ARGS_LOG:-/dev/null}"
fi
exit 0
STUB
  chmod +x "${b}/claude"
  printf '%s' "${b}"
}

workdir="$(mktemp -d "${tmproot}/work.XXXXXX")"

# apply with a valid config: records `mcp add` with the URL + literal env-var header (no token)
h_apply="$(make_home)"; write_config "${h_apply}" "tok-apply-secret" "wss://apply.test/machine/ws?vsn=2.0.0"
stub="$(stub_claude_bin)"; argslog="${tmproot}/apply-args.$$"
: > "${argslog}"
set +e
( cd "${workdir}" && HOME="${h_apply}" PATH="${stub}:${PATH}" CLAUDE_ARGS_LOG="${argslog}" "${add_mcp}" ) >/dev/null 2>&1
rc=$?
set -e
assert_eq "apply exits 0 with a valid config" "0" "${rc}"
recorded="$(cat "${argslog}")"
assert_contains "apply records the derived /mcp URL" "${recorded}" "https://apply.test/mcp"
assert_contains "apply records the literal env-var header" "${recorded}" 'Bearer ${ATHENA_MCP_BEARER}'
case "${recorded}" in *tok-apply-secret*) fail "apply leaked the token into mcp add" ;; *) pass "apply does not leak the token into mcp add" ;; esac

# apply with a tokenless config: dies before `mcp add` (the .token presence guard)
h_apply2="$(make_home)"; write_config "${h_apply2}" "" "wss://apply.test/ws"
stub2="$(stub_claude_bin)"; argslog2="${tmproot}/apply2-args.$$"
: > "${argslog2}"
set +e
out="$( cd "${workdir}" && HOME="${h_apply2}" PATH="${stub2}:${PATH}" CLAUDE_ARGS_LOG="${argslog2}" "${add_mcp}" 2>&1 )"
rc=$?
set -e
assert_eq "apply on a tokenless config exits non-zero" "1" "${rc}"
assert_eq "apply on a tokenless config never calls mcp add" "0" "$(wc -c < "${argslog2}" | tr -d ' ')"

if [ "${fails}" -eq 0 ]; then
  echo "add-athena-mcp self-test: OK"
  exit 0
else
  echo "add-athena-mcp self-test: ${fails} failure(s)"
  exit 1
fi
