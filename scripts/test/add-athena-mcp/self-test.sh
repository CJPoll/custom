#!/usr/bin/env bash
# Discovered self-test for scripts/add-athena-mcp and the launcher scripts/athena.
#
# Covers:
#   * add-athena-mcp --help: stdout only, exit 0, no side effects (repo rule).
#   * add-athena-mcp --dry-run URL derivation: from a stub inbox config's
#     server_url; a --url override; and the failed-lookup case — an absent or
#     server_url-less config falls back to the default URL, observably.
#   * DND-839: the machine token never reaches the launched session's
#     environment. A child of the launch (what every Bash tool command is) sees
#     no ATHENA_MCP_BEARER — not from the config, not inherited from the caller
#     — while the athena MCP connect still carries `Authorization: Bearer
#     <token>`, minted by the registered headersHelper from the 0600 config.
#   * scripts/athena preflight: a present-but-tokenless or unreadable config,
#     or a missing jq, HARD-FAILS loudly (exit 1 + Fix:); an ABSENT config is
#     environment-safe (launch proceeds) so an unrelated `claude` launch is
#     never broken; a legacy ${ATHENA_MCP_BEARER} registration is named loudly.
#   * add-athena-mcp apply: registers the headersHelper through `mcp add-json`,
#     never a token and never the env-var header; refuses when the helper
#     cannot mint a header.
#
# No real `claude` CLI or real inbox config is touched: HOME is redirected to a
# temp tree and `claude` is a stub (below) that plays the parts of Claude Code
# this depends on. Every token is a sentinel.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
add_mcp="${here}/../../add-athena-mcp"
launcher="${here}/../../athena"
helper="$(cd -- "${here}/../.." && pwd -P)/athena-mcp-headers"
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
assert_not_contains() { # desc haystack needle
  case "$2" in *"$3"*) fail "$1 (unexpected [$3])" ;; *) pass "$1" ;; esac
}

tmproot="$(mktemp -d)"
trap 'rm -rf "${tmproot}"' EXIT

# ── the stand-in for Claude Code ─────────────────────────────────────────────
# `claude mcp add|add-json|remove` edit $HOME/.claude.json the way the real CLI
# does at local scope (keyed by the cwd). Any other invocation is a LAUNCH: it
# reports whether its own environment carries ATHENA_MCP_BEARER (every Bash
# tool child inherits that environment), then plays the athena MCP connect for
# the entry registered for its cwd:
#   * headersHelper -> run it through a shell, as Claude Code does, with the
#     credential-shaped names (TOKEN/SECRET/PASSWORD/KEY/AUTH) scrubbed from
#     its environment, as Claude Code does for a local-scope helper;
#   * headers       -> expand ${ATHENA_MCP_BEARER} from this process's env.
# and reports whether the Authorization header is `Bearer $EXPECT_TOKEN`.
# That the real binary sends the helper's header on the MCP request is
# recorded separately (DND-839 report: a local listener received it).
stub_claude() { # <path>
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
cfg="${HOME}/.claude.json"; [ -s "${cfg}" ] || printf '{}' > "${cfg}"
key="$(pwd -P)"
put() { # <name> <entry-json>
  local t; t="$(mktemp)"
  jq --arg k "${key}" --arg n "$1" --argjson e "$2" '.projects[$k].mcpServers[$n] = $e' "${cfg}" > "${t}" && mv "${t}" "${cfg}"
}
if [ "${1:-}" = "mcp" ]; then
  printf '%s\n' "$*" >> "${CLAUDE_ARGS_LOG:-/dev/null}"
  sub="${2:-}"; shift 2
  pos=(); hdr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--scope|--transport|-t) shift ;;
      --header|-H) shift; hdr="${1:-}" ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  case "${sub}" in
    add-json) put "${pos[0]}" "${pos[1]}" ;;
    add) put "${pos[0]}" "$(jq -n -c --arg u "${pos[1]}" --arg h "${hdr#Authorization: }" '{type:"http", url:$u, headers:{Authorization:$h}}')" ;;
    remove) t="$(mktemp)"; jq --arg k "${key}" 'del(.projects[$k].mcpServers.athena)' "${cfg}" > "${t}" && mv "${t}" "${cfg}" ;;
  esac
  exit 0
fi
if [ -n "${ATHENA_MCP_BEARER+x}" ]; then cb=set; else cb=unset; fi
entry="$(jq -c --arg k "${key}" '.projects[$k].mcpServers.athena // empty' "${cfg}")"
auth=""; m=unregistered
if [ -n "${entry}" ]; then
  h="$(jq -r '.headersHelper // empty' <<<"${entry}")"
  if [ -n "${h}" ]; then
    scrub=(); for v in $(compgen -e); do case "${v^^}" in *TOKEN*|*SECRET*|*PASSWORD*|*KEY*|*AUTH*) scrub+=(-u "${v}") ;; esac; done
    auth="$(env "${scrub[@]}" sh -c "${h}" 2>/dev/null | jq -r '.Authorization // empty' 2>/dev/null)"
  else
    hv="$(jq -r '.headers.Authorization // empty' <<<"${entry}")"
    auth="${hv//\$\{ATHENA_MCP_BEARER\}/${ATHENA_MCP_BEARER:-}}"
  fi
  if [ "${auth}" = "Bearer ${EXPECT_TOKEN:-}" ]; then m=match; else m=mismatch; fi
fi
echo "CLAUDE_LAUNCHED child-bearer=${cb} mcp-auth=${m}"
STUB
  chmod +x "$1"
}

# A HOME with the stub `claude` at ~/.local/bin (the launcher's) and on PATH.
make_home() {
  local h; h="$(mktemp -d "${tmproot}/home.XXXXXX")"
  mkdir -p "${h}/.config/athena-inbox-client" "${h}/bin" "${h}/.local/bin"
  stub_claude "${h}/bin/claude"
  cp "${h}/bin/claude" "${h}/.local/bin/claude"
  printf '%s' "${h}"
}
write_config() { # home token server_url  (empty token => no .token key)
  local cfg="$1/.config/athena-inbox-client/config.json"
  if [ -n "$2" ]; then
    printf '{"token":"%s","server_url":"%s"}' "$2" "$3" > "${cfg}"
  else
    printf '{"server_url":"%s"}' "$3" > "${cfg}"
  fi
  chmod 600 "${cfg}"
}
# launch <home> <workdir> [VAR=value ...] -- runs the launcher from <workdir>
# with ATHENA_MCP_BEARER removed from the caller's env unless a VAR= sets it.
launch() {
  local h="$1" w="$2"; shift 2
  ( cd "${w}" && env -u ATHENA_MCP_BEARER HOME="${h}" "$@" "${launcher}" --x 2>&1 )
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
assert_contains "dry-run registers a headersHelper" "${out}" '"headersHelper"'
assert_not_contains "dry-run never registers the env-var header" "${out}" 'ATHENA_MCP_BEARER'
assert_not_contains "dry-run does not leak the token" "${out}" "tok-xyz"

# ── --dry-run: the default helper is the MAIN checkout's, never a worktree's ─
common="$(git -C "${here}" rev-parse --path-format=absolute --git-common-dir)"
assert_contains "dry-run helper defaults to the main checkout's copy" "${out}" "${common%/.git}/scripts/athena-mcp-headers"

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

# ── DND-839: register, launch, and look at what a child of the launch sees ───
sentinel="SENTINEL-dnd839-not-a-token"
h839="$(make_home)"; write_config "${h839}" "${sentinel}" "wss://s839.test/machine/ws?vsn=2.0.0"
w839="$(mktemp -d "${tmproot}/work.XXXXXX")"
set +e
( cd "${w839}" && HOME="${h839}" PATH="${h839}/bin:${PATH}" ATHENA_MCP_HEADERS_HELPER="${helper}" "${add_mcp}" ) >/dev/null 2>&1
rc=$?
set -e
assert_eq "DND-839: add-athena-mcp registers (exit 0)" "0" "${rc}"
out="$(launch "${h839}" "${w839}" EXPECT_TOKEN="${sentinel}" || true)"
assert_contains "DND-839: a child of the launch sees NO ATHENA_MCP_BEARER" "${out}" "child-bearer=unset"
assert_contains "DND-839: the MCP connect still carries Authorization: Bearer <token>" "${out}" "mcp-auth=match"

# A caller that exported the variable itself does not leak it into the session.
out="$(launch "${h839}" "${w839}" EXPECT_TOKEN="${sentinel}" ATHENA_MCP_BEARER="inherited-sentinel" || true)"
assert_contains "DND-839: an INHERITED ATHENA_MCP_BEARER is scrubbed from the session" "${out}" "child-bearer=unset"
assert_contains "DND-839: ... and the MCP still authenticates from the config" "${out}" "mcp-auth=match"

# ── launcher: a legacy ${ATHENA_MCP_BEARER} registration is named, loudly ────
h_leg="$(make_home)"; write_config "${h_leg}" "${sentinel}" "wss://x.test/ws"
w_leg="$(mktemp -d "${tmproot}/work.XXXXXX")"
( cd "${w_leg}" && HOME="${h_leg}" "${h_leg}/bin/claude" mcp add --transport http athena https://x.test/mcp --header 'Authorization: Bearer ${ATHENA_MCP_BEARER}' )
set +e
out="$(launch "${h_leg}" "${w_leg}")"; rc=$?
set -e
assert_eq "legacy registration: the launch still proceeds (exit 0)" "0" "${rc}"
assert_contains "legacy registration: a Fix: names add-athena-mcp" "${out}" "Fix: re-run scripts/add-athena-mcp"
assert_contains "legacy registration: the session still gets no bearer" "${out}" "child-bearer=unset"

# ── launcher: present-but-tokenless config HARD-FAILS with a Fix: ───────────
h5="$(make_home)"; write_config "${h5}" "" "wss://x.test/ws"
set +e
out="$(launch "${h5}" "${tmproot}")"; rc=$?
set -e
assert_eq "tokenless config exits non-zero" "1" "${rc}"
assert_contains "tokenless config prints a Fix:" "${out}" "Fix:"
assert_not_contains "claude not launched on a tokenless config" "${out}" "CLAUDE_LAUNCHED"

# ── launcher: PRESENT-but-unreadable config HARD-FAILS (not silent skip) ────
# A wrong-perms config is the Athena environment with a broken required input;
# it must NOT read as "absent" and take the env-safe skip. Skipped as root
# (root can read a 000 file, so the condition cannot be reproduced there).
if [ "$(id -u)" -ne 0 ]; then
  h_unread="$(make_home)"; write_config "${h_unread}" "tok-nr" "wss://x.test/ws"
  chmod 000 "${h_unread}/.config/athena-inbox-client/config.json"
  set +e
  out="$(launch "${h_unread}" "${tmproot}")"; rc=$?
  set -e
  chmod 600 "${h_unread}/.config/athena-inbox-client/config.json" 2>/dev/null || true
  assert_eq "unreadable-present config exits non-zero" "1" "${rc}"
  assert_contains "unreadable-present config prints a Fix:" "${out}" "Fix:"
  assert_not_contains "claude not launched on an unreadable config" "${out}" "CLAUDE_LAUNCHED"
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
stub_claude "${h6}/.local/bin/claude"
set +e
out="$(launch "${h6}" "${tmproot}")"; rc=$?
set -e
assert_eq "absent config launches claude (exit 0)" "0" "${rc}"
assert_contains "absent config does not break the launch" "${out}" "CLAUDE_LAUNCHED child-bearer=unset"

# ── add-athena-mcp APPLY path (non-dry-run) ─────────────────────────────────
# Run from a clean temp cwd (no .git) so the worktree warning does not fire.
workdir="$(mktemp -d "${tmproot}/work.XXXXXX")"

h_apply="$(make_home)"; write_config "${h_apply}" "tok-apply-secret" "wss://apply.test/machine/ws?vsn=2.0.0"
argslog="${tmproot}/apply-args.$$"; : > "${argslog}"
set +e
( cd "${workdir}" && HOME="${h_apply}" PATH="${h_apply}/bin:${PATH}" CLAUDE_ARGS_LOG="${argslog}" ATHENA_MCP_HEADERS_HELPER="${helper}" "${add_mcp}" ) >/dev/null 2>&1
rc=$?
set -e
assert_eq "apply exits 0 with a valid config" "0" "${rc}"
recorded="$(cat "${argslog}")"
assert_contains "apply registers through mcp add-json" "${recorded}" "mcp add-json"
assert_contains "apply records the derived /mcp URL" "${recorded}" "https://apply.test/mcp"
assert_contains "apply records the headersHelper path" "${recorded}" "\"headersHelper\":\"${helper}\""
assert_not_contains "apply never registers the env-var header" "${recorded}" "ATHENA_MCP_BEARER"
assert_not_contains "apply does not leak the token into mcp add-json" "${recorded}" "tok-apply-secret"
assert_eq "apply writes no token into ~/.claude.json" "" "$(grep -l "tok-apply-secret" "${h_apply}/.claude.json" 2>/dev/null || true)"

# apply with a tokenless config: dies before any `mcp add` (the helper cannot mint)
h_apply2="$(make_home)"; write_config "${h_apply2}" "" "wss://apply.test/ws"
argslog2="${tmproot}/apply2-args.$$"; : > "${argslog2}"
set +e
out="$( cd "${workdir}" && HOME="${h_apply2}" PATH="${h_apply2}/bin:${PATH}" CLAUDE_ARGS_LOG="${argslog2}" ATHENA_MCP_HEADERS_HELPER="${helper}" "${add_mcp}" 2>&1 )"
rc=$?
set -e
assert_eq "apply on a tokenless config exits non-zero" "1" "${rc}"
assert_contains "apply on a tokenless config prints a Fix:" "${out}" "Fix:"
assert_eq "apply on a tokenless config never calls mcp add" "" "$(grep ' add' "${argslog2}" || true)"

# apply with a helper path the shell would split: refused before any `mcp add`
h_apply3="$(make_home)"; write_config "${h_apply3}" "tok-3" "wss://apply.test/ws"
argslog3="${tmproot}/apply3-args.$$"; : > "${argslog3}"
set +e
out="$( cd "${workdir}" && HOME="${h_apply3}" PATH="${h_apply3}/bin:${PATH}" CLAUDE_ARGS_LOG="${argslog3}" ATHENA_MCP_HEADERS_HELPER="${tmproot}/has space/helper" "${add_mcp}" 2>&1 )"
rc=$?
set -e
assert_eq "apply with an unsafe helper path exits non-zero" "1" "${rc}"
assert_contains "apply with an unsafe helper path prints a Fix:" "${out}" "Fix:"
assert_eq "apply with an unsafe helper path never calls mcp add" "" "$(grep ' add' "${argslog3}" || true)"

if [ "${fails}" -eq 0 ]; then
  echo "add-athena-mcp self-test: OK"
  exit 0
else
  echo "add-athena-mcp self-test: ${fails} failure(s)"
  exit 1
fi
