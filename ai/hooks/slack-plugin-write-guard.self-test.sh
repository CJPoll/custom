#!/bin/sh
# Self-test for slack-plugin-write-guard.sh (DND-2043).
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts deny/allow per
# tool and caller. Caller shapes are the ones merge-role-guard measured on
# Claude Code 2.1.286 (DND-726, DND-1934): a subagent carries agent_id and
# agent_type; a plain top-level session carries neither; a top-level
# `claude [-p] --agent X` carries agent_type X and no agent_id. The hook's
# environment tells attended from headless: interactive
# CLAUDE_CODE_ENTRYPOINT=cli + CLAUDE_CODE_SESSION_ATTENDED=1, headless
# sdk-cli + 0. A case written <mode>:<who> runs the hook in that mode; a bare
# case runs it with both variables unset.
#
# THE REGRESSION CASE ("registry: ...") does not call the hook directly. It
# reads ai/hooks/registry.json, picks every PreToolUse row whose matcher
# matches the tool name (as Claude Code does), runs those scripts on a
# subagent's slack_send_message, and asserts one of them denies. On a tree
# with no such row (origin/main before DND-2043) the write is allowed and the
# case fails.
#
# THE TOOL LIST is the Slack plugin's own, as Claude Code listed it for
# slack@claude-plugins-official 1.3.0 on 2026-10-05 (27 tools). The plugin is a
# remote MCP server (https://mcp.slack.com/mcp); its list is not on disk. The
# guard keeps a READ allow-list, so a tool added later is denied until it is
# listed as a read (fail closed); the "future tool" cases pin that.
#
# Functional only (DND-1222): one pass, no load, no timing. Hermetic: HOME and
# XDG_STATE_HOME point into one trap-removed temp dir. Calls no Slack tool.
# SPW_SRC=<dir> runs against another ai/ tree (used for the regression
# evidence and the sabotage records).
#
# Exit 0 iff every case passes.

SRC_AI="${SPW_SRC:-$(cd -- "$(dirname -- "$(realpath -- "$0")")/.." && pwd -P)}"
HOOK="${SRC_AI}/hooks/slack-plugin-write-guard.sh"
REGISTRY="${SRC_AI}/hooks/registry.json"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not on PATH. Fix: install jq; the cases are built with it."; exit 1; }
[ -f "${REGISTRY}" ] || { echo "FAIL: ${REGISTRY} is missing. Fix: restore it from git, or point SPW_SRC at an ai/ tree that has it."; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed. Fix: check /tmp is writable."; exit 1; }
TMP=$(cd -- "${TMP}" && pwd -P)
trap 'rm -rf "${TMP}"' EXIT INT TERM
# Resolve the real ruby BEFORE HOME moves: a version-manager shim (asdf) needs
# the real HOME.
RUBY_BIN=$(ruby -e 'print RbConfig.ruby' 2>/dev/null)
[ -x "${RUBY_BIN}" ] || { echo "FAIL: no runnable ruby on PATH. Fix: install ruby; the hook's checker is ruby."; exit 1; }
mkdir -p "${TMP}/rubybin" && ln -sf "${RUBY_BIN}" "${TMP}/rubybin/ruby"
PATH="${TMP}/rubybin:${PATH}"
export HOME="${TMP}/home" XDG_STATE_HOME="${TMP}/state"
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ATTENDED RUBYLIB RUBYOPT
mkdir -p "${HOME}" "${XDG_STATE_HOME}"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1: $2"; }

P=mcp__plugin_slack_slack__
WRITES="slack_add_list_record slack_add_reaction slack_complete_file_upload slack_create_canvas
slack_create_conversation slack_create_list slack_get_file_upload_url slack_schedule_message
slack_send_message slack_send_message_draft slack_update_canvas slack_update_list
slack_update_list_record"
READS="slack_get_reactions slack_list_channel_members slack_list_user_channels slack_read_canvas
slack_read_channel slack_read_file slack_read_list slack_read_thread slack_read_user_profile
slack_search_channels slack_search_emojis slack_search_public slack_search_public_and_private
slack_search_users"

# payload <who> <tool> : PreToolUse stdin. who: sub (a subagent), top (no agent
# fields), agent:<type> (a top-level `--agent <type>`: agent_type, no agent_id).
payload() {
  case "$1" in
    sub) jq -nc --arg t "$2" '{session_id:"s1",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{channel_id:"CFAKE00001",message:"hello"},agent_id:"afake00001",agent_type:"general-purpose"}' ;;
    top) jq -nc --arg t "$2" '{session_id:"s1",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{channel_id:"CFAKE00001",message:"hello"}}' ;;
    agent:*) jq -nc --arg t "$2" --arg a "${1#agent:}" '{session_id:"s1",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{channel_id:"CFAKE00001",message:"hello"},agent_type:$a}' ;;
  esac
}

# run_hook <mode> <stdin> : prints the hook's stdout; RC holds its exit code.
# mode: cli (cli + 1), headless (sdk-cli + 0), half (cli, ATTENDED unset),
# none (both unset).
run_hook() {
  case "$1" in
    cli) OUT=$(printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 "${HOOK}" 2>/dev/null) ;;
    headless) OUT=$(printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0 "${HOOK}" 2>/dev/null) ;;
    half) OUT=$(printf '%s' "$2" | CLAUDE_CODE_ENTRYPOINT=cli "${HOOK}" 2>/dev/null) ;;
    none) OUT=$(printf '%s' "$2" | "${HOOK}" 2>/dev/null) ;;
  esac
  RC=$?
}

denied() { [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
has_fix() { printf '%s' "${OUT}" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Fix:")' >/dev/null 2>&1; }
allowed() { [ "${RC}" -eq 0 ] && [ -z "${OUT}" ]; }

expect_deny() { # <label> <mode> <stdin>
  run_hook "$2" "$3"
  if denied && has_fix; then ok "$1"; else bad "$1" "expected a deny with Fix:, got rc=${RC} out=${OUT}"; fi
}
expect_allow() { # <label> <mode> <stdin>
  run_hook "$2" "$3"
  if allowed; then ok "$1"; else bad "$1" "expected allow (exit 0, no output), got rc=${RC} out=${OUT}"; fi
}

# --- Regression: the wired registry denies a subagent's send ---------------
REG_OUT=$("${RUBY_BIN}" -rjson -e '
  reg = JSON.parse(File.read(ARGV[0])); root = File.expand_path("..", File.dirname(ARGV[0])) + "/.."
  tool = ARGV[1]; input = STDIN.read; denied = []
  (reg["hooks"] || []).each do |row|
    next unless row["event"] == "PreToolUse"
    m = row["matcher"].to_s
    next unless m.empty? || m == "*" || Regexp.new("\\A(?:#{m})\\z").match?(tool)
    script = File.join(File.expand_path(root), row["script"])
    next unless File.executable?(script)
    out = IO.popen([script], "r+", err: File::NULL) { |io| io.write(input); io.close_write; io.read }
    d = (JSON.parse(out) rescue nil)
    denied << row["script"] if d.is_a?(Hash) && d.dig("hookSpecificOutput", "permissionDecision") == "deny"
  end
  puts denied.join(",")
' "${REGISTRY}" "${P}slack_send_message" <<EOF
$(payload sub "${P}slack_send_message")
EOF
)
case "${REG_OUT}" in
  *slack-plugin-write-guard.sh*) ok "registry: a PreToolUse row denies a subagent's ${P}slack_send_message" ;;
  *) bad "registry: a PreToolUse row denies a subagent's ${P}slack_send_message" "no registered PreToolUse hook denied it (deniers: '${REG_OUT}'); the write is ALLOWED" ;;
esac
REG_MATCH=$(jq -r '[.hooks[] | select(.event == "PreToolUse" and .script == "ai/hooks/slack-plugin-write-guard.sh") | .matcher] | join(" ")' "${REGISTRY}")
case "${REG_MATCH}" in
  "") bad "registry: the guard has a PreToolUse row" "none in ${REGISTRY}" ;;
  *) for t in ${READS} ${WRITES}; do
       echo "${P}${t}" | "${RUBY_BIN}" -e 'm = ARGV[0]; t = STDIN.read.strip; exit(Regexp.new("\\A(?:#{m})\\z").match?(t) ? 0 : 1)' "${REG_MATCH}" \
         || bad "registry matcher covers ${t}" "matcher '${REG_MATCH}' does not match ${P}${t}"
     done
     ok "registry matcher '${REG_MATCH}' is checked against every plugin tool"
     # The matcher and the guard's SCOPE must agree on every name, whether
     # Claude Code anchors the matcher or not.
     # Each name is <expected scope>=<tool name>.
     for e in false=mcp__athena__slack_post false=mcp__athena__slack_react false=Bash \
              false=mcp__notion-personal__API-post-page false=mcp__claude_ai_Gmail__send_message \
              true=mcp__plugin_slack_slack__slack_send_message true=mcp__plugin_slack-by-salesforce_slack__slack_send_message \
              true=mcp__slack__slack_send_message true=mcp__slack-work__x true=mcp__claude_ai_Slack__slack_send_message \
              true=mcp__claude_ai_SLACK__slack_send_message; do
       want="${e%%=*}"; t="${e#*=}"
       V=$(echo "${t}" | "${RUBY_BIN}" -e '
         require File.join(ARGV[1], "lib", "slack_plugin_write")
         m = ARGV[0]; t = STDIN.read.strip
         a = Regexp.new("\\A(?:#{m})\\z").match?(t); u = Regexp.new(m).match?(t)
         s = !SlackPluginWrite.server_tool(t).nil?
         print(a == s && u == s ? "agree:#{s}" : "disagree anchored=#{a} unanchored=#{u} scope=#{s}")' "${REG_MATCH}" "${SRC_AI}" 2>&1)
       case "${V}" in
         "agree:${want}") ok "matcher and SCOPE agree on ${t} (in scope: ${want})" ;;
         agree:*) bad "matcher and SCOPE agree on ${t}" "both say in scope ${V#agree:}, expected ${want}" ;;
         *) bad "matcher and SCOPE agree on ${t}" "${V}" ;;
       esac
     done ;;
esac

# --- Every write is denied to a subagent; every read passes ----------------
for t in ${WRITES}; do expect_deny "subagent (attended parent): ${t} denied" cli "$(payload sub "${P}${t}")"; done
for t in ${READS}; do expect_allow "subagent: ${t} (read) allowed" cli "$(payload sub "${P}${t}")"; done

# --- Callers -----------------------------------------------------------------
expect_allow "attended top-level session: send allowed (the human-present exception)" cli "$(payload top "${P}slack_send_message")"
expect_allow "attended interactive --agent claude: send allowed" cli "$(payload agent:claude "${P}slack_send_message")"
expect_deny  "headless top-level claude -p: send denied" headless "$(payload top "${P}slack_send_message")"
expect_deny  "headless claude -p --agent claude: send denied" headless "$(payload agent:claude "${P}slack_send_message")"
expect_deny  "half mode signal (cli, ATTENDED unset): send denied" half "$(payload top "${P}slack_send_message")"
expect_deny  "no mode signal: send denied" none "$(payload top "${P}slack_send_message")"
expect_deny  "subagent of a headless session: canvas write denied" headless "$(payload sub "${P}slack_create_canvas")"
expect_allow "headless top-level: read allowed" headless "$(payload top "${P}slack_read_channel")"
EMPTY_ID=$(jq -nc --arg t "${P}slack_send_message" '{tool_name:$t,tool_input:{},agent_id:"",agent_type:"general-purpose"}')
expect_deny  "empty agent_id with an agent_type: denied" cli "${EMPTY_ID}"
EMPTY_BOTH=$(jq -nc --arg t "${P}slack_send_message" '{tool_name:$t,tool_input:{},agent_id:"",agent_type:""}')
expect_deny  "empty agent_id and agent_type (the key is there): denied" cli "${EMPTY_BOTH}"
NULL_ID=$(jq -nc --arg t "${P}slack_send_message" '{tool_name:$t,tool_input:{},agent_id:null}')
expect_deny  "null agent_id (the key is there): denied" cli "${NULL_ID}"

# --- Fail closed: tools the read list does not name ----------------------
expect_deny "future tool slack_delete_message: denied" cli "$(payload sub "${P}slack_delete_message")"
expect_deny "future tool slack_read_new_thing (not listed): denied" cli "$(payload sub "${P}slack_read_new_thing")"
expect_deny "the same Slack server through another plugin: denied" cli "$(payload sub "mcp__plugin_slack-by-salesforce_slack__slack_send_message")"
expect_allow "the same server's read through another plugin: allowed" cli "$(payload sub "mcp__plugin_slack-by-salesforce_slack__slack_read_thread")"
expect_deny "a claude.ai Slack connector write: denied" cli "$(payload sub "mcp__claude_ai_Slack__slack_send_message")"
expect_deny "a user server named slack: denied" cli "$(payload sub "mcp__slack__slack_send_message")"
expect_deny "a user server named slack-work: denied" cli "$(payload sub "mcp__slack-work__slack_send_message")"
expect_deny "an upper-case claude.ai SLACK connector: denied" cli "$(payload sub "mcp__claude_ai_SLACK__slack_send_message")"
expect_allow "out of scope: mcp__athena__slack_post allowed" cli "$(payload sub "mcp__athena__slack_post")"
expect_allow "out of scope: Bash allowed" cli "$(payload sub Bash)"

# --- Fail closed: input it cannot evaluate -------------------------------
expect_deny "unparseable stdin: denied" cli "not json {"
expect_deny "empty stdin: denied" cli ""
expect_deny "JSON that is not an object: denied" cli '["x"]'
expect_deny "no tool_name: denied" cli '{"agent_id":"afake00001"}'

# No ruby on PATH: the shell answers with a deny itself.
NORUBY="${TMP}/noruby"
mkdir -p "${NORUBY}"
for c in cat dirname realpath date mkdir printf; do
  p=$(command -v "${c}" 2>/dev/null) && [ -n "${p}" ] && [ "${p#/}" != "${p}" ] && ln -sf "${p}" "${NORUBY}/${c}"
done
for t in slack_read_channel slack_send_message; do
  OUT=$(payload sub "${P}${t}" | PATH="${NORUBY}" "$(command -v bash)" "${HOOK}" 2>/dev/null); RC=$?
  if denied && has_fix; then ok "no ruby on PATH: ${t} denied with Fix:"; else bad "no ruby on PATH: ${t}" "rc=${RC} out=${OUT}"; fi
done

# A checker that dies before printing: the shell answers with a deny.
mkdir -p "${TMP}/badlib"
printf 'exit 3\n' > "${TMP}/badlib/json.rb"
OUT=$(payload top "${P}slack_read_channel" | RUBYLIB="${TMP}/badlib" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=1 "${HOOK}" 2>/dev/null); RC=$?
if denied && has_fix; then ok "checker exits before deciding: denied with Fix:"; else bad "checker exits before deciding" "rc=${RC} out=${OUT}"; fi

# --- Deny text, log, --help ------------------------------------------------
run_hook cli "$(payload sub "${P}slack_send_message")"
if printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'mcp__athena__slack_post' \
   && printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'athena:slack'; then
  ok "deny Fix: names mcp__athena__slack_post and athena:slack"
else
  bad "deny Fix: names the bot path" "${OUT}"
fi
LOG="${XDG_STATE_HOME}/athena/slack-plugin-write-guard.log"
if [ -s "${LOG}" ] && grep -q 'slack_send_message' "${LOG}" && grep -q 'general-purpose' "${LOG}"; then
  ok "denies are logged with tool and caller"
else
  bad "denies are logged" "no matching line in ${LOG}"
fi
if [ -s "${LOG}" ] && grep -q 'hello' "${LOG}"; then bad "the log never keeps the message text" "found tool_input text in ${LOG}"; else ok "the log never keeps the message text"; fi
H=$("${HOOK}" --help </dev/null); RC=$?
if [ "${RC}" -eq 0 ] && printf '%s' "${H}" | grep -q 'slack-plugin-write-guard'; then ok "--help on stdout, exit 0"; else bad "--help" "rc=${RC}"; fi

echo
echo "slack-plugin-write-guard self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read each FAIL line above; fix ai/hooks/slack-plugin-write-guard.sh, ai/lib/slack_plugin_write*.rb or ai/hooks/registry.json (or the case, if the case is wrong)."
  exit 1
fi
exit 0
