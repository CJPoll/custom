#!/usr/bin/env bash
# Self-test for ai/bin/check-machine-secrets and ai/bin/with-secret (DND-845).
# Contract: ai/contracts/athena-machine-secrets.md.
#
# Hermetic and functional (no load): a fixture copy of the tools in a git repo
# whose allowlist and registry have LANDED on a local bare origin, a fake HOME,
# a fake XDG_STATE_HOME, and `env -i`, so the runner's own environment (which
# may hold a real secret) never reaches the tool.
#
# SYNTHETIC VALUES ONLY, and none is spelled literally in this file: each is
# built at runtime from pieces, so this public file carries nothing a secret
# scanner (or probe (d)) would match. Every case's stdout+stderr is appended to
# one transcript, and the last case asserts no synthetic value appears in it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "${HERE}/../../.." && pwd -P)"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
# The fixture's own git commands read no global or system git config (DND-1436).
# An owner's ~/.gitconfig (init.defaultBranch=main) once made a fixture pass on
# the host and fail in tool-sandbox, whose HOME is empty. Hermetic here, the
# fixture fails the same way everywhere, so it has to name its branches itself.
: > "${TMP}/gitconfig-empty"
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig-empty" GIT_CONFIG_NOSYSTEM=1
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${@:2}"; FAIL=$((FAIL+1)); }

# --- synthetic values, assembled so no literal matches a credential pattern
P_ANT="sk-""ant-"
P_XOX="xo""xb-"
SYN_A="${P_ANT}SYNTHaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
SYN_B="${P_XOX}SYNTHbbbbbbbbbbbbbbbbbb2"
SYN_C="plainSYNTHccccccccccccccc3"
SYN_D="${P_ANT}SYNTHdddddddddddddddddddddddddddd4"
ALL_SYN=("${SYN_A}" "${SYN_B}" "${SYN_C}" "${SYN_D}")
TRANSCRIPT="${TMP}/transcript"
: > "${TRANSCRIPT}"

# --- fixture repo: the tools, their libs, a landed bar ---------------------
REPO="${TMP}/repo"
ORIGIN="${TMP}/origin.git"
FHOME="${TMP}/home"
STATE="${TMP}/state"
mkdir -p "${REPO}/ai/bin" "${REPO}/ai/lib" "${REPO}/ai/secrets" "${REPO}/ai/inbox" "${REPO}/dotfiles" "${FHOME}" "${STATE}"
for f in ai/bin/check-machine-secrets ai/bin/with-secret ai/lib/machine_secrets.rb ai/lib/machine_secrets_host.rb \
         ai/lib/landed.rb ai/lib/strict_argv.rb ai/lib/private_overlay.rb ai/lib/private_overlay_resolver.rb; do
  cp "${SRC}/${f}" "${REPO}/${f}" || { echo "FAIL: copy ${f}"; exit 1; }
done
printf 'plain dotfile\n' > "${REPO}/dotfiles/.zshrc"

write_allowlist() { # <extra exact names...>
  local extra="" n
  for n in "$@"; do extra="${extra}, \"${n}\""; done
  cat > "${REPO}/ai/secrets/env-allowlist.json" <<EOF
{"kind":"athena-machine-secrets-env-allowlist","schema":1,
 "exact":["HL_INITIAL_WORKSPACE_TOKEN"${extra}],"rules":["file-path","git-config-key"]}
EOF
}
entry() { # <name> <path> [kind] [copies]
  local copies=""
  [ -n "${4:-}" ] && copies=",\"copies\":\"$4\""
  printf '{"name":"%s","path":"%s","consumers":["fixture"],"kind":"%s","restart":"none","rotate":"fixture"%s}' \
    "$1" "$2" "${3:-token}" "${copies}"
}
write_registry() { # <entry json...>
  local IFS=,
  printf '{"kind":"athena-machine-secrets","schema":1,"secrets":[%s]}\n' "$*" > "${REPO}/ai/secrets/registry.json"
}
BASE_ENTRIES=(
  "$(entry fx-token '~/.fx/token')"
  "$(entry fx-link '~/.fx/link')"
  "$(entry fx-absent '~/.fx/absent')"
  "$(entry fx-dotenv '~/.fx/app/.env' dotenv '~/wt/*/app/.env')"
  "$(entry SYN_KEY '~/.fx/syn-key' api-key)"
  "$(entry SYN_DOTENV '~/.fx/app/.env' dotenv)"
  "$(entry SYN_ABSENT '~/.fx/never-provisioned' api-key)"
)
write_allowlist
write_registry "${BASE_ENTRIES[@]}"

TENANT="${TMP}/tenant"
mkdir -p "${TENANT}/backend/ai-artifacts/node_modules/pkg"
git -C "${TENANT}" init -q -b main
cat > "${REPO}/ai/inbox/registry.json" <<EOF
{"v":1,"projects":[{"file":"tenant.json","entry":{"repo":"${TENANT}/.git"}},
                   {"file":"gone.json","entry":{"repo":"~/no-such-repo/.git"}}]}
EOF

git -C "${REPO}" init -q -b main
git -C "${REPO}" -c user.email=t@example.invalid -c user.name=t add -A
git -C "${REPO}" -c user.email=t@example.invalid -c user.name=t commit -q -m landed
git init -q --bare -b main "${ORIGIN}"
git -C "${REPO}" remote add origin "${ORIGIN}"
git -C "${REPO}" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
git -C "${REPO}" fetch -q origin >/dev/null 2>&1
restore_repo() { git -C "${REPO}" checkout -q -- ai/secrets; git -C "${REPO}" remote set-url origin "${ORIGIN}"; }

# --- fixture home ----------------------------------------------------------
mkdir -p "${FHOME}/.fx/app" "${FHOME}/.claude" "${FHOME}/dev/proj/lib"
chmod 700 "${FHOME}/.fx"
( umask 077; printf '%s\n' "${SYN_C}" > "${FHOME}/.fx/token"; printf '%s\n' "${SYN_C}" > "${FHOME}/.fx/target"
  printf '%s\n' "${SYN_A}" > "${FHOME}/.fx/syn-key"; printf 'A=%s\n' "${SYN_C}" > "${FHOME}/.fx/app/.env" )
ln -s target "${FHOME}/.fx/link"

# run <tool> [VAR=value ...] -- <args...> : clean env; sets OUT, RC.
run() {
  local tool="$1"; shift
  local vars=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  OUT="$(env -i PATH=/usr/bin:/bin HOME="${FHOME}" XDG_STATE_HOME="${STATE}" LANG=C.UTF-8 "${vars[@]}" \
           "${REPO}/ai/bin/${tool}" "$@" 2>&1 </dev/null)"; RC=$?
  printf '%s\n' "${OUT}" >> "${TRANSCRIPT}"
}
check() { run check-machine-secrets "$@"; }

# expect <label> <rc> [regex that must appear] [regex that must NOT appear]
expect() {
  local label="$1" want="$2" must="${3:-}" mustnot="${4:-}"
  if [ "${RC}" != "${want}" ]; then bad "${label}" "exit ${RC}, want ${want}" "${OUT}"; return; fi
  if [ -n "${must}" ] && ! grep -Eq -- "${must}" <<<"${OUT}"; then bad "${label}" "missing /${must}/" "${OUT}"; return; fi
  if [ -n "${mustnot}" ] && [ -n "${OUT}" ] && grep -Eq -- "${mustnot}" <<<"${OUT}"; then bad "${label}" "unexpected /${mustnot}/" "${OUT}"; return; fi
  ok "${label}"
}

# has_fix <label>: the last output carries a line starting "Fix: ".
has_fix() {
  if grep -q '^Fix: ' <<<"${OUT}"; then ok "$1 carries a Fix: line"; else bad "$1 carries a Fix: line" "${OUT}"; fi
}

echo "machine-secrets self-test (tools: ${SRC}/ai/bin)"

# ---------------------------------------------------------------- schema
# The COMMITTED registry and allowlist parse under the schema the tools use.
if OUT="$(/usr/bin/ruby -e 'require ARGV[0]
  MachineSecrets.parse_registry(File.read(ARGV[1]), "registry").each { |e| MachineSecrets.path_problem(e.path) && abort("bad path #{e.name}") }
  MachineSecrets.parse_allowlist(File.read(ARGV[2]), "allowlist")
  puts "parsed"' "${SRC}/ai/lib/machine_secrets.rb" "${SRC}/ai/secrets/registry.json" "${SRC}/ai/secrets/env-allowlist.json" 2>&1)" \
   && [ "${OUT}" = parsed ]; then ok "schema: the committed registry and allowlist parse"
else bad "schema: the committed registry and allowlist parse" "${OUT}"; fi
if /usr/bin/ruby -e 'require ARGV[0]; al = MachineSecrets.parse_allowlist(File.read(ARGV[1]), "a")
  exit(al.exact.none? { |n| n.include?("*") } && !al.exact.include?("CLAUDE_CODE_OAUTH_TOKEN") ? 0 : 1)' \
   "${SRC}/ai/lib/machine_secrets.rb" "${SRC}/ai/secrets/env-allowlist.json"; then
  ok "schema: the committed allowlist has no wildcard and no CLAUDE_CODE_OAUTH_TOKEN"
else bad "schema: the committed allowlist has no wildcard and no CLAUDE_CODE_OAUTH_TOKEN" "see ai/secrets/env-allowlist.json"; fi

# ---------------------------------------------------------------- --help
check -- --help
expect "check --help: stdout, exit 0" 0 "^check-machine-secrets --"
run with-secret -- --help
expect "with-secret --help: stdout, exit 0" 0 "^with-secret --"
check -- --probe z
expect "unknown probe is a usage error with a Fix" 2 "Fix:"

# ---------------------------------------------------------------- probe (a)
check -- --probe a
expect "(a) clean env -> exit 0" 0 "CLEAN"
check "SYN_API_KEY=${SYN_C}" -- --probe a
expect "(a) a credential NAME fires" 1 "FAIL  SYN_API_KEY is in this process's env: its name"
check "INNOCENT=${SYN_A}" -- --probe a
expect "(a) a credential VALUE under an innocent name fires" 1 "FAIL  INNOCENT .*value has a credential prefix"
check "MY_PAT=${SYN_C}" -- --probe a
expect "(a) PAT as a word fires" 1 "MY_PAT"
check "PATH_LIKE=${SYN_C}" -- --probe a
expect "(a) PAT inside a word does not" 0 "CLEAN"
check "HL_INITIAL_WORKSPACE_TOKEN=${SYN_C}" -- --probe a
expect "(a) a landed allowlist name is excused" 0 "CLEAN"
check "CLAUDE_CODE_OAUTH_TOKEN=${SYN_C}" -- --probe a
expect "(a) CLAUDE_CODE_OAUTH_TOKEN is reported, not allowlisted" 1 "CLAUDE_CODE_OAUTH_TOKEN"
check "GIT_CONFIG_KEY_0=${SYN_C}" -- --probe a
expect "(a) GIT_CONFIG_KEY_n rule excuses" 0 "CLEAN"
check "SYN_TOKEN_FILE=${FHOME}/.fx/token" -- --probe a
expect "(a) a _FILE var naming an existing path is excused" 0 "CLEAN"
check "SYN_TOKEN_FILE=${FHOME}/.fx/nope" -- --probe a
expect "(a) a _FILE var naming no path is reported" 1 "SYN_TOKEN_FILE"
write_allowlist BRANCH_ONLY_TOKEN
check "BRANCH_ONLY_TOKEN=${SYN_C}" -- --probe a
expect "(a) an allowlist entry added on the branch is NOT honoured" 1 "BRANCH_ONLY_TOKEN" "CLEAN"
git -C "${REPO}" remote set-url origin "${TMP}/no-such-origin.git"
check "HL_INITIAL_WORKSPACE_TOKEN=${SYN_C}" -- --probe a
expect "(a) landed allowlist unreadable -> allowlisted name is could-not-measure, exit 3" 3 "COULD NOT MEASURE  HL_INITIAL_WORKSPACE_TOKEN"
check "HL_INITIAL_WORKSPACE_TOKEN=${SYN_C}" "SYN_API_KEY=${SYN_C}" -- --probe a
expect "(a) unreadable allowlist + a real finding -> exit 1 (finding wins)" 1 "FAIL  SYN_API_KEY"
check "HL_INITIAL_WORKSPACE_TOKEN=${SYN_C}" -- --probe a,c
expect "(c) origin unreachable: the landed-registry line names the failed ls-remote" 3 \
  "COULD NOT MEASURE  the landed registry could not be read.*git ls-remote origin refs/heads/main"
expect "(a) origin unreachable: the unverified line names the failed ls-remote" 3 \
  "COULD NOT MEASURE  HL_INITIAL_WORKSPACE_TOKEN.*git ls-remote origin refs/heads/main"
restore_repo
# A STALE local origin/main (origin moved since the last fetch; measured on the
# laptop 2026-09-30) is a different cause with a different Fix: the Fix must
# name the two SHAs and `git fetch origin`, never "make origin reachable".
STALE_BASE="$(git -C "${REPO}" rev-parse refs/remotes/origin/main)"
git clone -q -b main "${ORIGIN}" "${TMP}/mover" >/dev/null 2>&1
git -C "${TMP}/mover" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "origin moves"
git -C "${TMP}/mover" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
STALE_NEW="$(git -C "${TMP}/mover" rev-parse HEAD)"
# The cases below prove nothing unless origin really moved one commit past the
# local ref. Say so here, naming the three SHAs, before the downstream cases miss.
ORIGIN_NOW="$(git --git-dir="${ORIGIN}" rev-parse --verify -q refs/heads/main)"
if [ -n "${ORIGIN_NOW}" ] && [ "${ORIGIN_NOW}" = "${STALE_NEW}" ] \
   && [ "$(git --git-dir="${ORIGIN}" rev-parse -q --verify "${ORIGIN_NOW}^")" = "${STALE_BASE}" ]; then
  ok "(fixture) origin's main moved one commit past the local origin/main"
else
  bad "(fixture) origin's main moved one commit past the local origin/main" \
    "local origin/main ${STALE_BASE:-<none>}, mover HEAD ${STALE_NEW:-<none>}, origin main ${ORIGIN_NOW:-<none>}"
fi
check "HL_INITIAL_WORKSPACE_TOKEN=${SYN_C}" -- --probe a,c
expect "(c) stale local origin/main: the Fix names both SHAs and git fetch origin" 3 \
  "COULD NOT MEASURE  the landed registry could not be read.*${STALE_BASE:0:12}.*${STALE_NEW:0:12}" "make origin reachable"
expect "(c) stale local origin/main: its Fix is git fetch origin" 3 "Fix: git fetch origin, then re-run"
expect "(a) stale local origin/main: the unverified Fix names the stale ref" 3 \
  "COULD NOT MEASURE  HL_INITIAL_WORKSPACE_TOKEN.*${STALE_BASE:0:12}"
git -C "${TMP}/mover" push -q -f origin "${STALE_BASE}:refs/heads/main" >/dev/null 2>&1
rm -rf "${TMP}/mover"
check "SYN_API_KEY=${SYN_C}" -- --probe a --brief
expect "(a) --brief: one line per name with Fix" 1 "^secret-env-warn: SYN_API_KEY .*Fix: move SYN_API_KEY" "allowlist"
check -- --probe a --brief
expect "(a) --brief clean prints nothing" 0 "" "."

# ---------------------------------------------------------------- probe (b)
printf '# a comment\nexport OTHER=1\nexport SYN_API_KEY="%s"\n# export OLD_TOKEN=%s\n' "${SYN_C}" "${SYN_C}" > "${FHOME}/.zshrc.local"
chmod 644 "${FHOME}/.zshrc.local"
check -- --probe b
expect "(b) an export in ~/.zshrc.local is FILE:LINE NAME" 1 "FAIL  ~/.zshrc.local:3 SYN_API_KEY" "OLD_TOKEN"
expect "(b) a readable init file with a finding is its own finding" 1 "~/.zshrc.local is mode 0644 .*holds a finding"
if [ -f "${STATE}/athena/machine-secrets/exports.json" ] && grep -q '"SYN_API_KEY"' "${STATE}/athena/machine-secrets/exports.json" \
   && [ "$(stat -c %a "${STATE}/athena/machine-secrets/exports.json")" = 600 ]; then
  ok "(b) records the export in exports.json (0600)"
else bad "(b) records the export in exports.json (0600)" "record missing or mode wrong"; fi
printf 'export PLAIN=%s\n' "${SYN_A}" > "${FHOME}/.zprofile"
check -- --probe b
expect "(b) a credential VALUE under an innocent name fires" 1 "~/.zprofile:1 PLAIN"
rm -f "${FHOME}/.zprofile"
cat > "${FHOME}/.claude.json" <<EOF
{"mcpServers":{"lit":{"env":{"SVC_TOKEN":"${SYN_C}"}},"ref":{"env":{"SVC_TOKEN":"\${SVC_TOKEN}"},"headers":{"Authorization":"Bearer \${T}"}},
 "hdr":{"headers":{"Authorization":"Bearer ${SYN_C}"}},"arg":{"args":["--api-key=${SYN_C}"]}}}
EOF
check -- --probe b
expect "(b) literal MCP env token fires" 1 "mcpServers.lit.env.SVC_TOKEN"
expect "(b) MCP \${VAR} reference does not" 1 "" "mcpServers.ref"
expect "(b) literal Bearer header fires" 1 "mcpServers.hdr.headers.Authorization"
expect "(b) --api-key=value in args fires" 1 "mcpServers.arg.args\[0\] API_KEY"
rm -f "${FHOME}/.claude.json"
cat > "${FHOME}/.claude.json" <<EOF
{"projects":{"/p":{"mcpServers":{"q":{"url":"https://example.invalid/mcp?token=${SYN_C}&x=1"},"clean":{"url":"https://example.invalid/mcp?x=1"}}}}}
EOF
check -- --probe b
expect "(b) a credential in a per-project MCP url query fires" 1 "projects\[/p\].mcpServers.q.url token" "clean"
rm -f "${FHOME}/.claude.json"
printf '{"env":{"SVC_API_KEY":"%s","SVC_KEY_FILE":"~/.fx/token","SVC_TOKEN_FILE":"%s/.fx/token","OTHER":"1"}}\n' "${SYN_C}" "${FHOME}" > "${FHOME}/.claude/settings.json"
chmod 600 "${FHOME}/.claude/settings.json"
check -- --probe b
expect "(b) a literal credential in settings.json env fires" 1 "~/.claude/settings.json:env.SVC_API_KEY SVC_API_KEY"
expect "(b) settings.json _FILE paths are not findings" 1 "" "SVC_KEY_FILE|SVC_TOKEN_FILE"
printf '{"env":{"SVC_TOKEN_FILE":"~/.fx/token"}}\n' > "${FHOME}/.claude/settings.json"
check -- --probe b
expect "(b) settings.json holding only a _FILE path is clean" 1 "" "FAIL  ~/.claude/settings.json"
rm -f "${FHOME}/.claude/settings.json"

# ---------------------------------------------------------------- PENDING RESTART
# The export at ~/.zshrc.local:3 is recorded (above). Remove it, then judge.
NOW="$(date +%s)"
check "SYN_API_KEY=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=$((NOW - 100))" -- --probe a
expect "(a) recorded export still present -> FAIL" 1 "still present at ~/.zshrc.local:3"
printf 'export OTHER=1\n' > "${FHOME}/.zshrc.local"
check "SYN_API_KEY=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=$((NOW - 100))" -- --probe a
expect "(a) recorded, gone, file changed after session start -> PENDING RESTART, exit 0" 0 "PENDING RESTART  SYN_API_KEY"
# The same state with a HOME that is not a fixture: the seam is ignored, so it
# cannot relabel a live FAIL (the record's paths are absolute, so HOME=/ still
# finds them).
check "HOME=/" "SYN_API_KEY=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=$((NOW - 100))" -- --probe a
expect "(a) the session-start seam is ignored outside a fixture HOME -> FAIL" 1 "FAIL  SYN_API_KEY" "PENDING"
touch -d "@$((NOW - 200))" "${FHOME}/.zshrc.local"
# Another probed file (the symlinked ~/.zshrc, whose target a git pull would
# bump) changed after the start: only the RECORDED file's own mtime counts.
ln -sf "${REPO}/dotfiles/.zshrc" "${FHOME}/.zshrc"
touch "${REPO}/dotfiles/.zshrc"
check "SYN_API_KEY=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=$((NOW - 100))" -- --probe a
expect "(a) recorded, gone, file older than start (another file newer) -> FAIL" 1 "did not change after this session started" "PENDING"
check "SYN_API_KEY=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=none" -- --probe a
expect "(a) no claude ancestor -> FAIL, never pending" 1 "no ancestor claude process"
# A symlinked dotfile whose TARGET moved after session start, with no record:
# the newest mtime of any file must not stand in for a recorded export.
ln -sf "${REPO}/dotfiles/.zshrc" "${FHOME}/.zshrc"
touch "${REPO}/dotfiles/.zshrc"
check "UNRECORDED_TOKEN=${SYN_C}" "CHECK_MS_TEST_CLAUDE_START=$((NOW - 100))" -- --probe a
expect "(a) symlinked dotfile moved after start, no record -> FAIL" 1 "FAIL  UNRECORDED_TOKEN .*no recorded export" "PENDING"
rm -f "${FHOME}/.zshrc" "${FHOME}/.zshrc.local"

# ---------------------------------------------------------------- probe (c)
check -- --probe c
expect "(c) a regular 0600 file passes" 0 "ok    fx-token ~/.fx/token"
expect "(c) an absent entry is listed by name, not failed" 0 "not provisioned here: fx-absent"
expect "(c) a symlink names link and target" 0 "fx-link ~/.fx/link -> ~/.fx/target"
expect "(c) a copies glob that matches nothing says 0 matched" 0 "copies fx-dotenv ~/wt/\*/app/.env: 0 matched, 0 violator"
chmod 644 "${FHOME}/.fx/target"
check -- --probe c
expect "(c) a symlink's TARGET mode is checked" 1 "FAIL  fx-link ~/.fx/link -> ~/.fx/target: mode 0644.*"
expect "(c) its Fix is chmod 600 on the target" 1 "Fix: chmod 600 ~/.fx/target"
chmod 600 "${FHOME}/.fx/target"
mkdir -p "${FHOME}/wt/one/app" "${FHOME}/wt/two/app"
ln -s "${FHOME}/.fx/app/.env" "${FHOME}/wt/one/app/.env"
printf 'A=%s\n' "${SYN_C}" > "${FHOME}/wt/two/app/.env"; chmod 644 "${FHOME}/wt/two/app/.env"
check -- --probe c
expect "(c) copies: counts matches and violators" 1 "copies fx-dotenv ~/wt/\*/app/.env: 2 matched, 1 violator"
expect "(c) copies: names the 0644 copy" 1 "FAIL  fx-dotenv copy ~/wt/two/app/.env: mode 0644"
# A copies glob with a `*/*` segment must match dotfiles (.boto) but never the
# `.` directory entry: with FNM_DOTMATCH a bare `*` also matches `.`, which
# made `dir/./sub` a "copy" that is not a regular file (measured live on the
# desktop 2026-09-30: gcloud legacy_credentials/./<account> read as violators).
chmod 600 "${FHOME}/wt/two/app/.env"
mkdir -p "${FHOME}/.fx/gdir/acct"; chmod 700 "${FHOME}/.fx/gdir" "${FHOME}/.fx/gdir/acct"
( umask 077; printf 'x\n' > "${FHOME}/.fx/gdir/acct/.boto" )
write_registry "${BASE_ENTRIES[@]}" "$(entry fx-gdir '~/.fx/token' token '~/.fx/gdir/*/*')"
check -- --probe c
expect "(c) a */* copies glob matches a dotfile and not the . entry" 0 "copies fx-gdir ~/.fx/gdir/\*/\*: 1 matched, 0 violator" "gdir/\./"
restore_repo; rm -rf "${FHOME}/.fx/gdir"; chmod 644 "${FHOME}/wt/two/app/.env"
# Every probe (c) refusal branch, one at a time.
chmod 770 "${FHOME}/.fx"
check -- --probe c
expect "(c) a group-writable parent directory is a finding" 1 "FAIL  fx-token ~/.fx/token: parent directory mode 0770 is group- or world-writable"
expect "(c) its Fix is chmod 700 on the directory" 1 "Fix: chmod 700 ~/.fx"
chmod 700 "${FHOME}/.fx"
mv "${FHOME}/.fx/target" "${FHOME}/.fx/target.moved"
check -- --probe c
expect "(c) a dangling symlink is a finding, not 'not provisioned'" 1 "FAIL  fx-link ~/.fx/link -> \(dangling\): a dangling symlink"
mv "${FHOME}/.fx/target.moved" "${FHOME}/.fx/target"
mkdir -p "${FHOME}/.fx/absent"
check -- --probe c
expect "(c) a declared path that is a directory is a finding" 1 "FAIL  fx-absent ~/.fx/absent: not a regular file"
rmdir "${FHOME}/.fx/absent"
rm -rf "${FHOME}/wt"
write_registry "${BASE_ENTRIES[@]}" "$(entry rel-path 'secrets/relative')"
check -- --probe c
expect "(c) a wrongly-computed (relative) registry path is could-not-measure" 3 "path is neither absolute nor"
write_registry "${BASE_ENTRIES[@]}" "$(entry leaky '~/.fx/x' token)"
sed -i "s|\"rotate\":\"fixture\"}]|\"rotate\":\"${SYN_B}\"}]|" "${REPO}/ai/secrets/registry.json"
check -- --probe c
expect "(c) a registry field holding a credential value is malformed (and not echoed)" 3 "looks like a credential value"
# A pasted value used as the entry NAME: every message names entries, so this
# is the field most likely to echo. Refused by position, never by name.
write_registry "${BASE_ENTRIES[@]}" "$(entry "${SYN_D}" '~/.fx/x' token)"
check -- --probe c
expect "(c) a credential-valued NAME is malformed and not echoed" 3 "secrets\[7\]: name looks like a credential value" "SYNTHd"
run with-secret -- SYN_KEY -- /bin/true
expect "with-secret: a credential-valued NAME in the registry is refused and not echoed" 1 "looks like a credential" "SYNTHd"
run with-secret -- "${SYN_A}" -- /bin/true
expect "with-secret: a value passed as NAME is refused and not echoed" 1 "NAME argument looks like a credential value" "SYNTHa"
restore_repo
check "HOME=relative/home" -- --probe c
expect "(c) a relative HOME is could-not-measure, not a pass" 3 "HOME .* not absolute|HOME is unset"
write_registry "${BASE_ENTRIES[@]}" "$(entry branch-only '~/.fx/branch')"
( umask 022; printf 'x\n' > "${FHOME}/.fx/landed-only" ); chmod 644 "${FHOME}/.fx/landed-only"
restore_repo
# Land an entry, then remove it on the branch: it is still checked.
write_registry "${BASE_ENTRIES[@]}" "$(entry landed-only '~/.fx/landed-only')"
git -C "${REPO}" -c user.email=t@example.invalid -c user.name=t commit -q -am "land landed-only"
git -C "${REPO}" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${REPO}" fetch -q origin >/dev/null 2>&1
write_registry "${BASE_ENTRIES[@]}"
check -- --probe c
expect "(c) a landed entry removed on the branch is still checked" 1 "FAIL  landed-only ~/.fx/landed-only: mode 0644"
restore_repo; rm -f "${FHOME}/.fx/landed-only"

# ---------------------------------------------------------------- probe (d)
mkdir -p "${REPO}/ai-artifacts/ctx"
printf 'note\nKEY=%s\n' "${SYN_A}" > "${REPO}/ai-artifacts/ctx/note.md"
printf 'the prefix %s alone is prose\n' "${P_ANT}" > "${REPO}/ai-artifacts/ctx/prose.md"
printf 'x=%s\n' "${SYN_D}" > "${TENANT}/backend/ai-artifacts/leak.txt"
printf 'x=%s\n' "${SYN_D}" > "${TENANT}/backend/ai-artifacts/node_modules/pkg/vendored.txt"
printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\004\000' > "${FHOME}/dev/proj/core.4242"
printf 'defmodule Core do\nend\n%s\n' "${SYN_A}" > "${FHOME}/dev/proj/lib/core.ex"
mkdir -p "${FHOME}/dev/proj/node_modules"; cp "${FHOME}/dev/proj/core.4242" "${FHOME}/dev/proj/node_modules/core.1"
check -- --probe d
expect "(d) a value in this repo's ai-artifacts is reported by path" 1 "FAIL  .*/repo/ai-artifacts/ctx/note.md"
expect "(d) a bare prefix in prose is not a finding" 1 "" "prose.md"
expect "(d) a tenant repo's nested ai-artifacts is scanned" 1 "FAIL  .*/tenant/backend/ai-artifacts/leak.txt"
expect "(d) node_modules is skipped and counted" 1 "[1-9][0-9]* dir\(s\) skipped" "vendored.txt"
expect "(d) the scanned roots are listed" 1 "roots .*repo.*tenant"
expect "(d) a registry repo missing here is named" 1 "no-such-repo/.git \(gone.json\): not on this machine"
expect "(d) an ELF core dump is reported by path and size" 1 "FAIL  core dump ~/dev/proj/core.4242 \(18 bytes\)"
expect "(d) core.ex is not a core dump" 1 "" "core.ex"
rm -rf "${REPO}/ai-artifacts" "${FHOME}/dev/proj" "${TENANT}/backend/ai-artifacts/leak.txt"
check -- --probe d
expect "(d) clean trees -> exit 0" 0 "0 finding"

# ---------------------------------------------------------------- with-secret
run with-secret -- SYN_KEY -- /bin/sh -c 'printf "len=%s args=%s" "${#SYN_KEY}" "$*"' argv0 one
expect "with-secret: the value reaches the child's env" 0 "len=${#SYN_A} args=one"
run with-secret -- SYN_KEY -- /bin/sh -c 'cat /proc/$$/cmdline | tr "\0" " "'
expect "with-secret: the value is not in the child's argv" 0 "/bin/sh -c"
run with-secret -- SYN_ABSENT -- /bin/true
expect "with-secret: a declared file that does not exist is refused" 1 "never-provisioned does not exist on this machine"
has_fix "with-secret: a declared file that does not exist is refused"
run with-secret -- NO_SUCH -- /bin/true
expect "with-secret: an unknown name is refused with a Fix" 1 "Fix:"
has_fix "with-secret: an unknown name is refused with a Fix"
run with-secret -- SYN_DOTENV -- /bin/true
expect "with-secret: a dotenv entry is refused" 1 "is a dotenv entry"
has_fix "with-secret: a dotenv entry is refused"
chmod 644 "${FHOME}/.fx/syn-key"
run with-secret -- SYN_KEY -- /bin/true
expect "with-secret: a 0644 file is refused with chmod Fix" 1 "Fix: chmod 600 ~/.fx/syn-key"
has_fix "with-secret: a 0644 file is refused with chmod Fix"
chmod 600 "${FHOME}/.fx/syn-key"
: > "${FHOME}/.fx/syn-key"
run with-secret -- SYN_KEY -- /bin/true
expect "with-secret: an empty file is refused" 1 "syn-key is empty"
has_fix "with-secret: an empty file is refused"
printf '%s\n' "${SYN_A}" > "${FHOME}/.fx/syn-key"
run with-secret -- SYN_KEY
expect "with-secret: a missing command is a usage error" 2 "Fix:"
has_fix "with-secret: a missing command is a usage error"
run with-secret -- fx-token -- /bin/true
expect "with-secret: a name that is not an env identifier is refused" 1 "not an env variable name"
has_fix "with-secret: a name that is not an env identifier is refused"
mkdir -p "${FHOME}/.config/athena/work/overlay"; chmod 700 "${FHOME}/.config/athena/work"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${FHOME}/.config/athena/work/athena-overlay.json"
printf '{"kind":"athena-machine-secrets","schema":1,"secrets":[%s]}\n' "$(entry OVL_KEY '~/.fx/syn-key' api-key)" > "${FHOME}/.config/athena/work/overlay/secrets.json"
run with-secret -- OVL_KEY -- /bin/sh -c 'printf "len=%s" "${#OVL_KEY}"'
expect "with-secret: an overlay entry resolves" 0 "len=${#SYN_A}"
check -- --probe c
expect "(c) overlay entries are checked" 0 "overlay 1\).*|ok    OVL_KEY"
printf '{"kind":"athena-machine-secrets","schema":1,"secrets":[%s]}\n' "$(entry SYN_KEY '~/.fx/token' api-key)" > "${FHOME}/.config/athena/work/overlay/secrets.json"
check -- --probe c
expect "(c) a name in both the public and the overlay registry is could-not-measure" 3 "SYN_KEY is declared in both"
run with-secret -- SYN_KEY -- /bin/true
expect "with-secret: a name in both registries is refused" 1 "declared in both"
has_fix "with-secret: a name in both registries is refused"
printf '{"kind":"athena-machine-secrets","schema":1,"secrets":[%s]}\n' "$(entry "${SYN_B}" '~/.fx/syn-key' api-key)" > "${FHOME}/.config/athena/work/overlay/secrets.json"
check -- --probe c
expect "(c) a credential-valued NAME in the overlay is could-not-measure and not echoed" 3 "overlay's secrets are not checked" "SYNTHb"
run with-secret -- OVL_KEY -- /bin/true
expect "with-secret: a credential-valued overlay NAME is refused and not echoed" 1 "overlay's registry could not be read" "SYNTHb"
printf 'not json' > "${FHOME}/.config/athena/work/overlay/secrets.json"
check -- --probe c
expect "(c) a malformed overlay registry is could-not-measure" 3 "overlay's secrets are not checked"
run with-secret -- SYN_KEY -- /bin/true
expect "with-secret: a malformed overlay refuses even a public name (uniqueness unknown)" 1 "overlay's registry could not be read"
has_fix "with-secret: a malformed overlay refuses even a public name (uniqueness unknown)"
rm -rf "${FHOME}/.config/athena"

# ---------------------------------------------------------------- no value, ever
leaked=0
for v in "${ALL_SYN[@]}"; do
  if grep -qF -- "${v}" "${TRANSCRIPT}"; then leaked=$((leaked+1)); fi
done
# with-secret's first case printed only a length; the transcript must still
# hold no value at all.
if [ "${leaked}" -eq 0 ] && [ -s "${TRANSCRIPT}" ]; then ok "no synthetic value reached stdout or stderr in any case"
else bad "no synthetic value reached stdout or stderr in any case" "${leaked} value(s) found in the transcript"; fi

echo "machine-secrets self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
