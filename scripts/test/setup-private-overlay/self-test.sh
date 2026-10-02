#!/usr/bin/env bash
# Self-test for scripts/setup-private-overlay (DND-703).
#
# Hermetic. Nothing on the real machine is read or written:
#   - the installer runs from a FIXTURE COPY of the repo (a temp git repo with
#     one linked worktree), so "the main checkout" and its .git/hooks are the
#     fixture's;
#   - HOME is a temp dir, so the default overlay root is the fixture's;
#   - `claude` is a stub on PATH that keeps its marketplace/plugin state in a
#     temp dir and logs every call; the real CLI is not on PATH;
#   - CLAUDE_CONFIG_DIR points at a temp dir as a second guard;
#   - pushes go to a temp bare repo.
# Synthetic values only (SYNTHWORK-<n>); no work-domain value appears here.
#
# Every gap case feeds a MISSING or WRONG input and asserts the installer says
# which, never "OK" (~/dev/custom/CLAUDE.md -> "A failed lookup must never look
# like an empty one").
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "${HERE}/../../.." && pwd -P)"

# A space in every fixture path exercises the hook's quoted exec line and the
# marketplace path comparison.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/setup private overlay.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

REAL_RUBY=/usr/bin/ruby
[ -x "$REAL_RUBY" ] || { echo "FAIL: /usr/bin/ruby missing (harness Ruby)"; exit 1; }

# ---- fixture repo: a copy of just what the installer and the hook run ----------
REPO="${TMP}/repo"
mkdir -p "${REPO}/ai/bin" "${REPO}/ai/lib" "${REPO}/ai/git-hooks" "${REPO}/ai/private-overlay" "${REPO}/scripts"
cp "${SRC}/scripts/setup-private-overlay" "${REPO}/scripts/"
cp "${SRC}/ai/bin/outbound-scan" "${SRC}/ai/bin/private-overlay" "${REPO}/ai/bin/"
cp "${SRC}"/ai/lib/*.rb "${REPO}/ai/lib/"
cp "${SRC}/ai/git-hooks/outbound-pre-push.sh" "${REPO}/ai/git-hooks/"
cp -R "${SRC}/ai/private-overlay/skeleton" "${REPO}/ai/private-overlay/"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.com"
export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.com"
git -C "$REPO" init --quiet -b main
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "fixture"
BARE="${TMP}/remote.git"
git init --quiet --bare "$BARE"
git -C "$REPO" remote add origin "$BARE"
git -C "$REPO" push --quiet origin main 2>/dev/null   # no hook yet
WT="${TMP}/wt"
git -C "$REPO" worktree add --quiet -b feature "$WT" main
HOOK="${REPO}/.git/hooks/pre-push"

# ---- stub claude ------------------------------------------------------------
STUB_BIN="${TMP}/bin"; STATE="${TMP}/claude-state"
mkdir -p "$STUB_BIN" "$STATE"
: > "${STATE}/mkts"; : > "${STATE}/plugins"; : > "${STATE}/calls.log"
cat > "${STUB_BIN}/claude" <<'RUBY'
#!/usr/bin/ruby
# Stub `claude plugin ...` for setup-private-overlay's self-test.
require "json"
st = ENV.fetch("CLAUDE_STUB_STATE")
File.open(File.join(st, "calls.log"), "a") { |f| f.puts ARGV.join(" ") }
mkts = File.readlines(File.join(st, "mkts"), chomp: true).map { |l| l.split("\t", 2) }
plugs = File.readlines(File.join(st, "plugins"), chomp: true).map { |l| l.split("\t", 2) }
save = lambda do
  File.write(File.join(st, "mkts"), mkts.map { |m| m.join("\t") + "\n" }.join)
  File.write(File.join(st, "plugins"), plugs.map { |p| p.join("\t") + "\n" }.join)
end
broken = ENV["CLAUDE_STUB_BROKEN"] == "1"
args = ARGV.reject { |a| a == "--json" }
scope_i = args.index("--scope"); args.slice!(scope_i, 2) if scope_i
case args
in ["plugin", "marketplace", "list"]
  puts(broken ? "not json" : JSON.generate(mkts.map { |n, p| { "name" => n, "source" => "directory", "path" => p, "installLocation" => p } }))
in ["plugin", "list"]
  # A plugins line is id<TAB>enabled[<TAB>scope]; scope defaults to user.
  broken ||= ENV["CLAUDE_STUB_BROKEN_PLUGINS"] == "1"
  puts(broken ? "not json" : JSON.generate(plugs.map { |id, en| e, sc = en.split("\t", 2); { "id" => id, "version" => "0.1.0", "scope" => sc || "user", "enabled" => e == "true" } }))
in ["plugin", "marketplace", "add", path]
  name = JSON.parse(File.read(File.join(path, ".claude-plugin", "marketplace.json")))["name"]
  mkts << [name, path] unless mkts.any? { |n, _| n == name }
  save.call
in ["plugin", "marketplace", "remove", name]
  mkts.reject! { |n, _| n == name }; save.call
in ["plugin", "install", id]
  mk = id.split("@", 2).last
  abort "stub: marketplace #{mk} not found" unless mkts.any? { |n, _| n == mk }
  plugs << [id, "true"] unless plugs.any? { |i, _| i == id }
  save.call
in ["plugin", ("enable" | "disable") => verb, id]
  plugs.map! { |i, e| i == id ? [i, (verb == "enable").to_s] : [i, e] }; save.call
in ["plugin", "uninstall", id]
  plugs.reject! { |i, _| i == id }; save.call
else
  abort "stub claude: unhandled #{ARGV.inspect}"
end
RUBY
chmod +x "${STUB_BIN}/claude"
# DND-1667: a guard right behind the claude stub, so a stub that is missing or
# not executable fails the suite instead of reaching a real claude CLI on
# BASE_PATH (ai/lib/forge-stub-guard.sh).
. "${SRC}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/claude-guard" claude
fsg_require_stubs "${STUB_BIN}" claude

export CLAUDE_STUB_STATE="$STATE"
export CLAUDE_CONFIG_DIR="${TMP}/claude-config"
FHOME="${TMP}/home"; mkdir -p "$FHOME"
export HOME="$FHOME"
unset ATHENA_PRIVATE_ROOT ATHENA_OUTBOUND_WAIVE
export XDG_STATE_HOME="${TMP}/state"
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${STUB_BIN}:${FSG_DIR}:${BASE_PATH}"
OVERLAY="${FHOME}/.config/athena/work"
INST="${REPO}/scripts/setup-private-overlay"
INST_WT="${WT}/scripts/setup-private-overlay"

# run <out-var-prefix> <cmd...> : captures stdout+stderr and the exit code.
run() { OUT="$("$@" 2>&1)"; RC=$?; }
calls() { cat "${STATE}/calls.log"; }
reset_calls() { : > "${STATE}/calls.log"; }
writes_in_log() { grep -E ' (add|install|enable|disable|uninstall|remove) ' "${STATE}/calls.log" || true; }

echo "setup-private-overlay self-test"

# 1. --help: stdout, exit 0, nothing written.
out="$("$INST" --help 2>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && has "--init" "$out" && has "--check" "$out" && [ ! -e "${FHOME}/.config" ] && [ ! -s "${STATE}/calls.log" ]; then
  ok "1 --help on stdout, exit 0, no side effects"
else bad "1 --help" "rc=$rc out=${out:0:200}"; fi

# 2. --install with NO overlay: ABSENT, exit 3, Fix names --init, nothing changed.
reset_calls; run "$INST" --install
if [ "$RC" = 3 ] && has "overlay: ABSENT" "$OUT" && has "--init" "$OUT" && [ -z "$(writes_in_log)" ] && [ ! -e "$HOOK" ]; then
  ok "2 --install on an ABSENT overlay: exit 3, Fix names --init, no writes"
else bad "2 absent install" "rc=$RC out=$OUT"; fi

# 3. --install with a MALFORMED root (relative ATHENA_PRIVATE_ROOT): exit 4.
reset_calls; run env ATHENA_PRIVATE_ROOT=relative/path "$INST" --install
if [ "$RC" = 4 ] && has "overlay: MALFORMED" "$OUT" && [ -z "$(writes_in_log)" ]; then
  ok "3 --install on a MALFORMED overlay: exit 4, distinct from ABSENT"
else bad "3 malformed install" "rc=$RC out=$OUT"; fi

# 4. --init --dry-run creates nothing.
run "$INST" --init --dry-run
if [ "$RC" = 0 ] && has "(dry-run) would create ${OVERLAY}" "$OUT" && [ ! -e "$OVERLAY" ]; then
  ok "4 --init --dry-run names the target and creates nothing"
else bad "4 init dry-run" "rc=$RC out=$OUT"; fi

# 5. --init with a relative ATHENA_PRIVATE_ROOT refuses (exit 4), creates nothing.
run env ATHENA_PRIVATE_ROOT=rel "$INST" --init
if [ "$RC" = 4 ] && has "not an absolute path" "$OUT" && has "Fix:" "$OUT" && [ ! -e "${REPO}/rel" ]; then
  ok "5 --init refuses a relative ATHENA_PRIVATE_ROOT"
else bad "5 init relative" "rc=$RC out=$OUT"; fi

# 6. --init materialises the skeleton: 0700, marker valid, 1 local commit, no remote.
run "$INST" --init
mode="$(stat -c '%a' "$OVERLAY" 2>/dev/null)"
ncommits="$(git -C "$OVERLAY" rev-list --count HEAD 2>/dev/null)"
remotes="$(git -C "$OVERLAY" remote 2>/dev/null)"
status="$("${REPO}/ai/bin/private-overlay" status 2>/dev/null)"
loose="$(find "$OVERLAY" -path "${OVERLAY}/.git" -prune -o \( -perm /077 -print \) 2>/dev/null)"
if [ "$RC" = 0 ] && [ "$mode" = 700 ] && [ "$ncommits" = 1 ] && [ -z "$remotes" ] \
   && has "PRESENT root=" "$status" && [ -z "$loose" ] \
   && [ -f "${OVERLAY}/.claude-plugin/marketplace.json" ] && [ -f "${OVERLAY}/plugins/work/.claude-plugin/plugin.json" ] \
   && [ "$(cat "${OVERLAY}/overlay/slack.json")" = "{}" ] && [ -f "${OVERLAY}/README.md" ] \
   && has "WARNING: the overlay is now PRESENT with ZERO outbound patterns" "$OUT" && has "gh-athena refuses" "$OUT"; then
  ok "6 --init: root 0700, no group/other bits, PRESENT, one local commit, no remote, skeleton layout, zero-pattern WARNING"
else bad "6 init" "rc=$RC mode=$mode commits=$ncommits remotes=$remotes status=$status loose=$loose out=$OUT"; fi

# 7. --init again refuses to overwrite (exit 5); the root is unchanged.
before="$(git -C "$OVERLAY" rev-parse HEAD)"
run "$INST" --init
if [ "$RC" = 5 ] && has "already exists; refusing to overwrite" "$OUT" && [ "$(git -C "$OVERLAY" rev-parse HEAD)" = "$before" ]; then
  ok "7 --init refuses an existing root (exit 5), leaves it untouched"
else bad "7 init twice" "rc=$RC out=$OUT"; fi

# 8. --check before --install: every gap named, exit 1, read-only.
reset_calls; run "$INST" --check
if [ "$RC" = 1 ] && has "overlay: OK" "$OUT" && has "marketplace: MISSING" "$OUT" && has "plugin: MISSING" "$OUT" \
   && has "hook: NOT ACTIVE" "$OUT" && [ -z "$(writes_in_log)" ] && [ ! -e "$HOOK" ]; then
  ok "8 --check names each gap (marketplace/plugin MISSING, hook NOT ACTIVE), exit 1, no writes"
else bad "8 check before install" "rc=$RC out=$OUT calls=$(calls)"; fi

# 9. --install --dry-run changes nothing.
reset_calls; run "$INST" --install --dry-run
if has "(dry-run) would register marketplace custom-work" "$OUT" && has "(dry-run) would install plugin work@custom-work" "$OUT" \
   && [ -z "$(writes_in_log)" ] && [ ! -e "$HOOK" ]; then
  ok "9 --install --dry-run lists the steps and writes nothing"
else bad "9 install dry-run" "rc=$RC out=$OUT calls=$(calls)"; fi

# 10. --install with the skeleton's EMPTY pattern list: marketplace + plugin
#     installed; hook NOT written (the scanner cannot measure); exit 1.
reset_calls; run "$INST" --install
if [ "$RC" = 1 ] && grep -q "^plugin marketplace add ${OVERLAY} --scope user$" "${STATE}/calls.log" \
   && grep -q "^plugin install work@custom-work --scope user$" "${STATE}/calls.log" \
   && [ ! -e "$HOOK" ] && has "hook: NOT ACTIVE" "$OUT" && has "COULD NOT MEASURE" "$OUT"; then
  ok "10 --install with no patterns: plugin wired, hook withheld and reported NOT ACTIVE, exit 1"
else bad "10 install without patterns" "rc=$RC out=$OUT calls=$(calls)"; fi

# 11. Commit a synthetic pattern in the overlay; --install now writes the hook.
printf 'synthwork-id\tSYNTHWORK-[0-9]+\n' >> "${OVERLAY}/outbound/patterns.tsv"
git -C "$OVERLAY" commit --quiet -am "synthetic pattern"
reset_calls; run "$INST" --install
if [ "$RC" = 0 ] && [ -x "$HOOK" ] && grep -qxF "# athena-outbound-pre-push: installed by scripts/setup-private-overlay (DND-703)." "$HOOK" \
   && grep -qF "exec $(printf '%q' "${REPO}/ai/git-hooks/outbound-pre-push.sh")" "$HOOK" &&[ -z "$(writes_in_log)" ]; then
  ok "11 --install with a committed pattern writes the hook (exec of the MAIN checkout's script); no plugin re-install"
else bad "11 install hook" "rc=$RC out=$OUT hook=$(cat "$HOOK" 2>/dev/null)"; fi

# 12. --check: all OK, exit 0; gh-athena's mark check would see the hook.
run "$INST" --check
if [ "$RC" = 0 ] && has "overlay: OK" "$OUT" && has "marketplace: OK" "$OUT" && has "plugin: OK" "$OUT" && has "hook: OK" "$OUT" \
   && grep -q -e outbound-scan -e outbound-pre-push "$HOOK"; then
  ok "12 --check after install: four OK lines, exit 0; the hook carries gh-athena's mark"
else bad "12 check ok" "rc=$RC out=$OUT"; fi

# 13. Idempotent: a second --install changes nothing.
reset_calls; sum="$(sha256sum "$HOOK")"; run "$INST" --install
if [ "$RC" = 0 ] && has "nothing to install" "$OUT" && [ -z "$(writes_in_log)" ] && [ "$(sha256sum "$HOOK")" = "$sum" ]; then
  ok "13 --install is idempotent"
else bad "13 idempotent" "rc=$RC out=$OUT calls=$(calls)"; fi

# 14. From the linked worktree: the hook path is the MAIN checkout's.
run "$INST_WT" --check
if [ "$RC" = 0 ] && has "hook: OK (${HOOK} -> ${REPO}/ai/git-hooks/outbound-pre-push.sh)" "$OUT"; then
  ok "14 run from a linked worktree, --check reads the main checkout's hook and target"
else bad "14 worktree check" "rc=$RC out=$OUT"; fi

# 15. The hook fires: a push from the worktree carrying the synthetic value is
#     refused with the label only; a clean push goes through.
printf 'ref SYNTHWORK-42\n' > "${WT}/leak.txt"
git -C "$WT" add leak.txt && git -C "$WT" commit --quiet -m "add a file"
push_out="$(git -C "$WT" push origin feature 2>&1)"; push_rc=$?
if [ "$push_rc" != 0 ] && has "label=synthwork-id" "$push_out" && ! has "SYNTHWORK-42" "$push_out"; then
  ok "15a the installed hook refuses a push carrying a pattern; the value is not printed"
else bad "15a hook refuses" "rc=$push_rc out=$push_out"; fi
git -C "$WT" reset --quiet --hard main
printf 'harmless\n' > "${WT}/clean.txt"
git -C "$WT" add clean.txt && git -C "$WT" commit --quiet -m "clean"
push_out="$(git -C "$WT" push origin feature 2>&1)"; push_rc=$?
if [ "$push_rc" = 0 ] && has "CLEAN" "$push_out"; then
  ok "15b the installed hook lets a clean push through (CLEAN)"
else bad "15b hook clean" "rc=$push_rc out=$push_out"; fi

# 16. A foreign pre-push hook is never overwritten; --check says NOT ACTIVE.
cp "$HOOK" "${TMP}/ours.hook"
printf '#!/bin/sh\nexit 0\n' > "$HOOK"; chmod +x "$HOOK"
run "$INST" --install
if [ "$RC" = 1 ] && has "hook: NOT ACTIVE" "$OUT" && has "did not write" "$OUT" && [ "$(cat "$HOOK")" = "$(printf '#!/bin/sh\nexit 0')" ]; then
  ok "16 a foreign pre-push hook is reported and left untouched"
else bad "16 foreign hook" "rc=$RC out=$OUT"; fi
run "$INST" --check
if [ "$RC" = 1 ] && has "hook: NOT ACTIVE" "$OUT" && ! has "hook: OK" "$OUT"; then
  ok "16b --check on a foreign hook: NOT ACTIVE, never OK"
else bad "16b foreign check" "rc=$RC out=$OUT"; fi

# 17. This installer's hook aimed at another checkout is STALE and refreshed.
{ sed -n '1,2p' "${TMP}/ours.hook"; printf 'exec /elsewhere/checkout/ai/git-hooks/outbound-pre-push.sh "$@"\n'; } > "$HOOK"
run "$INST" --check; stale_rc=$RC; stale_out="$OUT"
run "$INST" --install
if [ "$stale_rc" = 1 ] && has "hook: NOT ACTIVE" "$stale_out" && [ "$RC" = 0 ] && cmp -s "$HOOK" "${TMP}/ours.hook"; then
  ok "17 a stale own hook reads NOT ACTIVE and --install refreshes it"
else bad "17 stale hook" "check_rc=$stale_rc check=$stale_out rc=$RC out=$OUT"; fi

# 18. A disabled plugin is enabled.
sed -i 's/\ttrue$/\tfalse/' "${STATE}/plugins"
run "$INST" --check; dis_out="$OUT"
reset_calls; run "$INST" --install
if has "plugin: DISABLED" "$dis_out" && [ "$RC" = 0 ] && grep -q "^plugin enable work@custom-work --scope user$" "${STATE}/calls.log"; then
  ok "18 a disabled plugin is reported DISABLED and enabled by --install"
else bad "18 disabled" "check=$dis_out rc=$RC calls=$(calls)"; fi

# 19. `claude` not on PATH: COULD NOT MEASURE (exit 3), never MISSING.
run env PATH="$BASE_PATH" "$INST" --check
if [ "$RC" = 3 ] && has "marketplace: COULD NOT MEASURE" "$OUT" && has "plugin: COULD NOT MEASURE" "$OUT" && ! has "MISSING" "$OUT"; then
  ok "19 no claude CLI: COULD NOT MEASURE, exit 3, not MISSING"
else bad "19 no claude" "rc=$RC out=$OUT"; fi

# 20. `claude` prints unparseable JSON: COULD NOT MEASURE; --install writes nothing.
reset_calls; run env CLAUDE_STUB_BROKEN=1 "$INST" --install
if [ "$RC" = 3 ] && has "did not print valid JSON" "$OUT" && [ -z "$(writes_in_log)" ]; then
  ok "20 unparseable claude output: COULD NOT MEASURE, exit 3, no writes"
else bad "20 broken json" "rc=$RC out=$OUT calls=$(calls)"; fi

# 21. custom-work registered from ANOTHER path: CONFLICT, never re-added, and
#     the plugin is not installed from it.
cp "${STATE}/mkts" "${TMP}/mkts.ok"; cp "${STATE}/plugins" "${TMP}/plugins.ok"
printf 'custom-work\t/some/other/place\n' > "${STATE}/mkts"; : > "${STATE}/plugins"
reset_calls; run "$INST" --install
if [ "$RC" = 1 ] && has "marketplace: CONFLICT" "$OUT" && has "not the overlay root" "$OUT" && [ -z "$(writes_in_log)" ]; then
  ok "21 a custom-work marketplace from another path: CONFLICT, no add, no plugin install"
else bad "21 conflict" "rc=$RC out=$OUT calls=$(calls)"; fi
# 21b. --remove with that foreign custom-work: neither the marketplace nor a
#      plugin installed from it is removed.
printf 'work@custom-work\ttrue\n' > "${STATE}/plugins"
reset_calls; run "$INST" --remove --dry-run; dry_out="$OUT"
reset_calls; run "$INST" --remove
if [ "$RC" = 1 ] && has "plugin: CONFLICT" "$OUT" && has "left in place" "$OUT" && [ -z "$(writes_in_log)" ] \
   && ! has "would uninstall" "$dry_out"; then
  ok "21b --remove leaves a plugin and marketplace this installer did not add"
else bad "21b remove conflict" "rc=$RC out=$OUT dry=$dry_out calls=$(calls)"; fi
cp "${TMP}/mkts.ok" "${STATE}/mkts"; cp "${TMP}/plugins.ok" "${STATE}/plugins"
# 21b removed our hook (it is ours, whatever the marketplace); put it back.
[ -e "$HOOK" ] || { cp "${TMP}/ours.hook" "$HOOK"; chmod +x "$HOOK"; }

# 21c. A hook that exists but cannot be read: COULD NOT MEASURE, never OK.
chmod 000 "$HOOK"
run "$INST" --check
chmod 755 "$HOOK"
if [ "$(id -u)" = 0 ]; then ok "21c skipped: root reads any file"
elif [ "$RC" = 3 ] && has "hook: COULD NOT MEASURE" "$OUT" && has "cannot be read" "$OUT"; then
  ok "21c an unreadable hook: COULD NOT MEASURE, exit 3"
else bad "21c unreadable hook" "rc=$RC out=$OUT"; fi

# 22. The hook installed but the overlay's pattern floor gone (another root
#     with no patterns): --check says NOT ACTIVE, not OK.
EMPTY_ROOT="${TMP}/empty-overlay"
run env ATHENA_PRIVATE_ROOT="$EMPTY_ROOT" "$INST" --init
run env ATHENA_PRIVATE_ROOT="$EMPTY_ROOT" "$INST" --check
if [ "$RC" = 1 ] && has "hook: NOT ACTIVE" "$OUT" && has "cannot measure" "$OUT" && ! has "hook: OK" "$OUT"; then
  ok "22 hook present but the scanner cannot measure: NOT ACTIVE, never OK"
else bad "22 inert hook" "rc=$RC out=$OUT"; fi

# 22b. The overlay gone (ABSENT) while custom-work is registered: the installer
#      cannot vouch for the marketplace, so --check says UNVERIFIED (never OK)
#      and --remove leaves marketplace and plugin in place.
run env ATHENA_PRIVATE_ROOT="${TMP}/no-such-overlay" "$INST" --check; unv_check="$OUT"
reset_calls; run env HOME="${TMP}/other-home" "$INST" --remove --dry-run
if has "marketplace: UNVERIFIED" "$unv_check" && ! has "marketplace: OK" "$unv_check" \
   && has "marketplace: UNVERIFIED" "$OUT" && ! has "would uninstall" "$OUT" && ! has "would remove marketplace" "$OUT" \
   && [ -z "$(writes_in_log)" ]; then
  ok "22b overlay missing, custom-work registered: UNVERIFIED on --check; --remove keeps marketplace and plugin"
else bad "22b unverified" "check=$unv_check remove=$OUT"; fi

# 22c. work@custom-work installed only at PROJECT scope: not this installer's,
#      so it reads MISSING (naming the scope) and --install adds the user copy.
cp "${STATE}/plugins" "${TMP}/plugins.ok"
printf 'work@custom-work\ttrue\tproject\n' > "${STATE}/plugins"
run "$INST" --check; scope_check="$OUT"
reset_calls; run "$INST" --install --dry-run
if has "plugin: MISSING (work@custom-work is not installed at user scope (only at: project))" "$scope_check" \
   && has "(dry-run) would install plugin work@custom-work (user scope)" "$OUT"; then
  ok "22c a project-scope-only plugin reads MISSING (names the scope); --install would add the user-scope copy"
else bad "22c scope" "check=$scope_check install=$OUT"; fi
cp "${TMP}/plugins.ok" "${STATE}/plugins"

# 22d. --remove while the plugin list is unreadable: the marketplace is kept
#      (removing it could strand the plugin), and the gap is reported.
reset_calls; run env CLAUDE_STUB_BROKEN_PLUGINS=1 "$INST" --remove --dry-run
if [ "$RC" = 3 ] && has "plugin: COULD NOT MEASURE" "$OUT" && ! has "would remove marketplace" "$OUT"; then
  ok "22d unreadable plugin list: --remove keeps the marketplace, exit 3"
else bad "22d remove unmeasured" "rc=$RC out=$OUT"; fi

# 23. --remove --dry-run changes nothing; --remove undoes all three, keeps the overlay.
reset_calls; run "$INST" --remove --dry-run
if [ -z "$(writes_in_log)" ] && [ -e "$HOOK" ] && has "(dry-run) would remove the pre-push hook" "$OUT"; then
  ok "23a --remove --dry-run writes nothing"
else bad "23a remove dry-run" "rc=$RC out=$OUT"; fi
reset_calls; run "$INST" --remove
if [ "$RC" = 0 ] && [ ! -e "$HOOK" ] && grep -q "^plugin uninstall work@custom-work --scope user$" "${STATE}/calls.log" \
   && grep -q "^plugin marketplace remove custom-work --scope user$" "${STATE}/calls.log" && [ -f "${OVERLAY}/athena-overlay.json" ]; then
  ok "23b --remove removes hook, plugin and marketplace; the overlay directory stays"
else bad "23b remove" "rc=$RC out=$OUT calls=$(calls)"; fi

# 24. --remove leaves a foreign hook in place.
printf '#!/bin/sh\nexit 0\n' > "$HOOK"; chmod +x "$HOOK"
run "$INST" --remove
if [ -e "$HOOK" ] && has "did not write" "$OUT"; then
  ok "24 --remove never deletes a foreign hook"
else bad "24 remove foreign" "rc=$RC out=$OUT"; fi

# 25. Unknown argument: exit 1 with Fix.
run "$INST" --bogus
if [ "$RC" = 1 ] && has "Fix:" "$OUT"; then ok "25 unknown argument: exit 1 with Fix"; else bad "25 usage" "rc=$RC out=$OUT"; fi

# 26. The skeleton carries no work values: every overlay file is empty JSON,
#     and patterns.tsv holds comments only.
nonc="$(grep -v -e '^#' -e '^$' "${SRC}/ai/private-overlay/skeleton/outbound/patterns.tsv")"
if [ -z "$nonc" ] && [ "$(cat "${SRC}/ai/private-overlay/skeleton/overlay/slack.json")" = "{}" ] \
   && [ "$(cat "${SRC}/ai/private-overlay/skeleton/overlay/notion.json")" = "{}" ]; then
  ok "26 the public skeleton holds no values (empty overlay files, comment-only patterns)"
else bad "26 skeleton values" "patterns=$nonc"; fi

# DND-1667: no claude call may have fallen through past its stub.
if fsg_verify; then ok "no claude call fell through past its stub (DND-1667)"
else bad "no claude call fell through past its stub (DND-1667)" "see the forge-stub-guard FAIL above"; fi

TOTAL=$((PASS+FAIL))
if [ "$FAIL" = 0 ]; then
  echo "VERDICT: PASS (${TOTAL} setup-private-overlay cases)"
  exit 0
fi
echo "VERDICT: FAIL (${FAIL} of ${TOTAL} setup-private-overlay cases)"
exit 1
