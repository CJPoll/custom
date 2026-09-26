#!/bin/sh
# worktree-escape-guard.sh -- PreToolUse hook (ONE registry entry, matcher
# Bash|Edit|Write|MultiEdit|NotebookEdit; the hook branches on tool_name): an
# agent dispatched into a worktree may not write the MAIN checkout (DND-840).
# One entry, not two: scripts/setup-hooks dedupes on event + command, so a
# second entry for this script on PreToolUse would never be installed.
#
# ~/dev/custom/CLAUDE.md -> *Agents work in worktrees, not the main checkout*
# made this doctrine and named this hook as its honest choke point. Motivating
# incident, 2026-09-26: the DND-807 captain edited ai/agents/athena-captain.md.in
# and ai/skills/athena:flaky-ticket/SKILL.md in ~/dev/custom instead of its
# worktree, then reverted with `git checkout --` in the main checkout. Every
# session loaded the half-edited skill in between (~/.claude/skills resolves
# into the main checkout), and the revert would have destroyed anyone else's
# uncommitted edits to those files.
#
# WHO IS GUARDED (measured on Claude Code 2.1.283, see the self-test header):
#   * A SUBAGENT (stdin carries agent_id). Its Bash cwd resets to the session
#     root between calls and stdin's `cwd` is that root, so neither says where
#     it was dispatched. The doctrine binds every spawned agent, so every
#     subagent is guarded; its dispatch prompt (the first line of
#     <dir of transcript_path>/<session_id>/subagents/agent-<agent_id>.jsonl)
#     is read ONLY to name its worktree in the Fix:, never to decide.
#   * An UNATTENDED top-level session (CLAUDE_CODE_SESSION_ATTENDED != 1)
#     whose project dir (CLAUDE_PROJECT_DIR, else stdin cwd) is a linked
#     worktree -- e.g. a shipwright cron lane.
#   * NOT the attended top-level session: a human is present and asking (the
#     doctrine's fourth exception). It exits before python starts.
#   * NOT an unattended top-level session rooted in a main checkout: it was not
#     dispatched into a worktree, and it is where a main-checkout repair
#     happens (the doctrine's third exception).
#
# WHAT IS A MAIN CHECKOUT: a non-bare working tree whose git dir IS its common
# dir (not a linked worktree), that has a linked worktree or lives under
# ~/dev/. Paths are realpath'd first, so ~/.claude/skills/... is caught.
#
# WHAT IS DENIED, target inside a guarded main checkout:
#   * Edit/Write/MultiEdit/NotebookEdit of a path git does not ignore.
#   * Bash: a git subcommand in GIT_MUTATING (those that rewrite the working
#     tree or index, or switch or reset HEAD; `update-ref` / `symbolic-ref`
#     are not listed) run there (cwd,
#     -C, --work-tree, or a `cd` earlier in the same command); a redirection,
#     tee, sed -i, cp/mv/install/ln destination, mv source, rm, touch or
#     truncate on a path git does not ignore.
# ALLOWED there: `merge --ff-only` / `pull --ff-only` (publishing, the first
# exception), gitignored runtime state such as ai-artifacts/ (the second),
# fetch / worktree / branch / config, .git internals, and every read-only
# command. Quoted payloads, comments and heredoc bodies are never parsed as
# commands, so text that only MENTIONS a write is not a write.
#
# PARSED: `;` `&&` `||` `|` `&` newlines, subshells, `$( )` and backticks,
# reserved words (`if/then/do/{/!`), heredocs, `sh|bash|zsh|dash -c SCRIPT`
# (recursively), env/timeout/command-style wrappers, cd/pushd/popd, and git
# `--output`/`-o` files.
#
# NOT A SANDBOX. The guard models the forms agents actually type; a write
# shape it does not model passes WITHOUT a log line, and the list here is
# examples, not an inventory: interpreters (`python -c`, `perl -i`), `xargs`,
# `find -delete`, `eval`, writers outside the list above (`patch`, `tar -x`,
# `unzip`, `rsync`, `chmod`, `dd`), a substitution inside double quotes, and a
# target built from a variable not assigned in the same command. What IS
# logged: a target it cannot resolve (`unresolved`), a command it cannot
# tokenize (`unparsed`), and an input it cannot check (`unchecked`). By
# design, a scratch repo that has a linked worktree IS guarded wherever it
# lives: a subagent works in its worktree there too.
#
# FAILURE MODE: this hook runs on every tool call of every session on the
# machine, hot-loaded. A fail-closed hook would wedge them all on a broken git
# or python. So an input it cannot evaluate (unparseable stdin, no python3, a
# git error that is not "not a git repository", or the checker itself
# crashing -- logged `crashed`) is ALLOWED with a visible
# systemMessage + additionalContext and a log line -- loud, never silent.
# Every deny and every unresolved/unparsed case is appended to
# ${XDG_STATE_HOME:-~/.local/state}/athena/worktree-escape-guard.log.
#
# --self-test runs ai/hooks/worktree-escape-guard.self-test.sh.

case "${1:-}" in
  --self-test)
    exec "$(dirname -- "$(realpath -- "$0")")/worktree-escape-guard.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
worktree-escape-guard.sh -- Claude Code PreToolUse hook (Bash, Edit|Write|MultiEdit|NotebookEdit).
Reads the hook JSON on stdin. Denies a subagent (or an unattended top-level
session rooted in a linked worktree) writing a MAIN checkout's working tree:
file edits, mutating git, and obvious shell writes. The attended main session,
ff-only publishing, gitignored runtime state and read-only commands pass.
  --self-test   run ai/hooks/worktree-escape-guard.self-test.sh
EOF
    exit 0 ;;
esac

INPUT=$(cat 2>/dev/null)

# Fast path, no python: the attended top-level session (the human's own
# session) is never guarded. Needs jq only to see that agent_id is absent.
if [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "1" ] && command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "${INPUT}" | jq -r '.agent_id // empty' 2>/dev/null) && [ -z "${AGENT}" ] && \
    printf '%s' "${INPUT}" | jq -e 'type == "object"' >/dev/null 2>&1 && exit 0
fi

# Fast path: a Bash command with no write-shaped word cannot be denied.
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
  if [ "${TOOL}" = "Bash" ]; then
    CMD=$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
    case "${CMD}" in
      *git*|*'>'*|*tee*|*sed*|*cp*|*mv*|*rm*|*touch*|*ln*|*install*|*truncate*) ;;
      *) exit 0 ;;
    esac
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  WEG_LOG="${XDG_STATE_HOME:-${HOME}/.local/state}/athena/worktree-escape-guard.log"
  mkdir -p "$(dirname -- "${WEG_LOG}")" 2>/dev/null && \
    printf '%s\tunchecked\tno python3 on PATH\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${WEG_LOG}" 2>/dev/null
  printf '%s\n' '{"systemMessage":"worktree-escape-guard: python3 is not on PATH, so this tool call was NOT checked for a main-checkout write. Fix: install python3.","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"worktree-escape-guard could not run (no python3); this call was not checked. Fix: install python3."}}'
  exit 0
fi

PY=$(cat <<'PYEOF'
import json, os, re, subprocess, sys, time

HOME = os.environ.get("HOME", "")
STATE = os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state")
LOG = os.path.join(STATE, "athena", "worktree-escape-guard.log")
GENV = {k: v for k, v in os.environ.items()
        if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                     "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE", "GIT_PREFIX")}
WARNINGS = []

def log(kind, detail):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s\t%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), kind,
                                      detail.replace("\n", " ")[:600]))
    except OSError:
        pass

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.exit(0)

def allow_warn(msg, kind="unchecked"):
    log(kind, msg)
    emit({"systemMessage": "worktree-escape-guard: " + msg,
          "hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "additionalContext": "worktree-escape-guard could not check this call: " + msg}})

class Unresolved(Exception):
    pass

def git(args, cwd):
    try:
        return subprocess.run(["git"] + args, cwd=cwd, env=GENV, capture_output=True,
                              text=True, timeout=10)
    except FileNotFoundError:
        raise Unresolved("git is not on PATH")
    except subprocess.TimeoutExpired:
        raise Unresolved("git %s timed out in %s" % (" ".join(args[:2]), cwd))

def existing_dir(path):
    d = path
    while not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return d

REPOS = {}
def repo_of(path):
    """None when path is not in a working tree; else a dict describing its repo."""
    d = existing_dir(path)
    if d in REPOS:
        return REPOS[d]
    p = git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
             "--is-inside-work-tree", "--is-bare-repository"], d)
    if p.returncode != 0:
        if "not a git repository" in p.stderr:
            REPOS[d] = None
            return None
        raise Unresolved("git rev-parse in %s failed: %s" % (d, p.stderr.strip()[:200]))
    lines = p.stdout.split("\n")
    git_dir, common, inside, bare = lines[0], lines[1], lines[2], lines[3]
    if inside != "true" or bare == "true":
        REPOS[d] = None
        return None
    t = git(["rev-parse", "--path-format=absolute", "--show-toplevel"], d)
    if t.returncode != 0:
        raise Unresolved("git rev-parse --show-toplevel in %s failed: %s" % (d, t.stderr.strip()[:200]))
    info = {"top": os.path.realpath(t.stdout.strip()),
            "git_dir": os.path.realpath(git_dir), "common": os.path.realpath(common)}
    info["main"] = info["git_dir"] == info["common"]
    REPOS[d] = info
    return info

def worktrees(info):
    if "worktrees" not in info:
        p = git(["worktree", "list", "--porcelain"], info["top"])
        if p.returncode != 0:
            raise Unresolved("git worktree list in %s failed: %s" % (info["top"], p.stderr.strip()[:200]))
        paths = [os.path.realpath(l[len("worktree "):]) for l in p.stdout.split("\n")
                 if l.startswith("worktree ")]
        info["worktrees"] = [w for w in paths if w != info["top"]]
    return info["worktrees"]

def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")

def guarded(info):
    if info is None or not info["main"]:
        return False
    devroot = os.path.realpath(os.path.join(HOME, "dev")) if HOME else None
    return bool(worktrees(info)) or (devroot is not None and under(info["top"], devroot))

def ignored(info, path):
    rel = os.path.relpath(path, info["top"])
    p = git(["check-ignore", "-q", "--", rel], info["top"])
    if p.returncode in (0, 1):
        return p.returncode == 0
    raise Unresolved("git check-ignore %s failed: %s" % (rel, p.stderr.strip()[:200]))

def in_git_dir(info, path):
    return under(path, info["git_dir"]) or under(path, info["common"])

# ---------------------------------------------------------------- the actor
def read_input():
    raw = sys.stdin.read()
    if not raw.strip():
        log("unchecked", "empty stdin")
        emit({})
    try:
        data = json.loads(raw)
    except ValueError:
        allow_warn("stdin was not JSON, so this tool call was NOT checked for a main-checkout write. "
                   "Fix: this is a Claude Code hook-contract change; update ai/hooks/worktree-escape-guard.sh.")
    if not isinstance(data, dict):
        allow_warn("stdin was not a JSON object; this call was NOT checked. "
                   "Fix: update ai/hooks/worktree-escape-guard.sh to the current hook contract.")
    return data

def dispatch_prompt(data):
    tp, sid, aid = data.get("transcript_path"), data.get("session_id"), data.get("agent_id")
    if not (tp and sid and aid):
        return None
    path = os.path.join(os.path.dirname(tp), sid, "subagents", "agent-%s.jsonl" % aid)
    try:
        with open(path) as f:
            first = json.loads(f.readline())
    except (OSError, ValueError):
        log("no-transcript", path)
        return None
    if not isinstance(first, dict) or not isinstance(first.get("message"), dict):
        log("no-transcript", "unexpected first-line shape in " + path)
        return None
    content = (first.get("message") or {}).get("content")
    if isinstance(content, list):
        content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    return content if isinstance(content, str) else None

def actor(data):
    """(kind, home_dir) or None when this caller is not guarded."""
    if data.get("agent_id"):
        return ("subagent", None)
    if os.environ.get("CLAUDE_CODE_SESSION_ATTENDED") == "1":
        return None
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd")
    if not proj:
        return None
    info = repo_of(os.path.realpath(proj))
    if info is None or info["main"]:
        return None
    return ("session", info["top"])

# ------------------------------------------------------------------ the fix
def pick_worktree(info, data, act):
    wts = worktrees(info)
    if act[1] and act[1] in wts:
        return act[1], "your session's project dir"
    prompt = dispatch_prompt(data) or ""
    hits = [w for w in wts if w in prompt]
    if hits:
        return max(hits, key=len), "the worktree your dispatch prompt named"
    return None, None

def deny(info, target, what, data, act):
    wt, why = pick_worktree(info, data, act)
    rel = os.path.relpath(target, info["top"]) if under(target, info["top"]) else None
    cwd = data.get("cwd") or "the session root"
    head = ("worktree-escape-guard: %s targets %s in the MAIN checkout %s. The main checkout is a "
            "shared surface -- other sessions and the owner work in it (and ~/dev/custom's is the live "
            "harness: ~/.claude/skills and hooks load from it) -- so a dispatched agent never writes it "
            "(~/dev/custom/CLAUDE.md -> Agents work in worktrees, not the main checkout). "
            % (what, target, info["top"]))
    if wt:
        fix = "Fix: make this change in %s (%s)" % (wt, why)
        if rel and rel != ".":
            fix += ": the same file there is %s" % os.path.join(wt, rel)
        fix += ". A subagent's Bash cwd resets to %s between calls, so put `cd %s && ...` in the SAME command, or use `git -C %s`." % (cwd, wt, wt)
    else:
        others = worktrees(info)
        if others:
            fix = ("Fix: make this change in your worktree of this repo (its linked worktrees: %s). "
                   "A subagent's Bash cwd resets to %s between calls, so `cd <worktree> && ...` in the SAME command."
                   % (", ".join(others[:6]), cwd))
        else:
            fix = ("Fix: create a worktree and work there: `git -C %s worktree add ~/.local/worktrees/%s/<branch> -b <branch> origin/main` (or `wt`); "
                   "or hand this change to the top-level session." % (info["top"], os.path.basename(info["top"])))
    tail = (" Still allowed in the main checkout: `git merge --ff-only` / `git pull --ff-only` (publishing), "
            "gitignored runtime state (e.g. ai-artifacts/), and read-only commands. If you already wrote "
            "the main checkout, do NOT undo it with `git checkout --`, `git restore` or `git reset` there: "
            "that destroys anyone else's uncommitted edits to those files. Report it to the top-level session instead.")
    reason = head + fix + tail
    log("deny", "%s agent=%s %s -> %s" % (data.get("tool_name"), data.get("agent_id") or "-", what, target))
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                 "permissionDecisionReason": reason}})

# --------------------------------------------------------- file-path tools
def check_path(path, what, data, act, honour_ignore=True):
    rp = os.path.realpath(path)
    info = repo_of(rp)
    if not guarded(info):
        return
    if in_git_dir(info, rp):
        return
    if honour_ignore and ignored(info, rp):
        return
    deny(info, rp, what, data, act)

# ------------------------------------------------------------------- bash
SEPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
REDIR_OUT = {">", ">>", ">|", "&>", "&>>"}
REDIR_SKIP = {"<", "<<", "<<<", ">&", "<&", "<>"}
UNKNOWN = object()

OPS = sorted(["&>>", "<<<", "<<-", ">>", "&>", ">|", ">&", "<&", "<<", "<>", "&&", "||", "|&",
              ";;", ";", "&", "|", "(", ")", "<", ">"], key=len, reverse=True)

def tokenize(text):
    """[(value, is_operator)]. An operator is recognised ONLY unquoted, so
    `grep '>' f` or a commit message containing `&&` is data, never syntax.
    Raises ValueError on an unterminated quote.

    A heredoc is recognised the same way: only an UNQUOTED `<<` / `<<-`
    operator (never `<<<`, a here-string, which OPS matches first) opens
    one, its next word is the delimiter, and the body -- data, not
    commands -- is skipped from the next newline to the delimiter line. A
    `<<EOF` inside a quoted argument is therefore just text."""
    toks, cur, have, i, n = [], [], False, 0, len(text)
    pending, want = [], [False]
    def flush():
        if have:
            word = "".join(cur)
            toks.append((word, False))
            if want[0]:
                pending.append(word)
                want[0] = False
        del cur[:]
        return False
    while i < n:
        c = text[i]
        if c in " \t\r":
            have = flush(); i += 1
        elif c == "\n":
            have = flush(); toks.append(("\n", True)); i += 1
            while pending and i < n:
                j = text.find("\n", i)
                line = text[i:j] if j >= 0 else text[i:]
                i = j + 1 if j >= 0 else n
                if line.strip() == pending[0]:
                    pending.pop(0)
        elif c == "#" and not have:
            while i < n and text[i] != "\n":
                i += 1
        elif c == "\\":
            if i + 1 < n and text[i + 1] != "\n":
                cur.append(text[i + 1]); have = True
            i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ValueError("unterminated single quote")
            cur.append(text[i + 1:j]); have = True; i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    cur.append(text[j + 1] if text[j + 1] in '"\\$`' else text[j:j + 2]); j += 2
                else:
                    cur.append(text[j]); j += 1
            if j >= n:
                raise ValueError("unterminated double quote")
            have = True; i = j + 1
        elif c == "`":
            # An unquoted backtick substitution runs its content as a command.
            have = flush(); toks.append((";", True)); i += 1
        elif c in ";&|()<>":
            have = flush()
            op = next(o for o in OPS if text.startswith(o, i))
            toks.append((op, True)); i += len(op)
            if op in ("<<", "<<-"):
                want[0] = True
        else:
            cur.append(c); have = True; i += 1
    flush()
    return toks

VAR = re.compile(r"\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")

def expand(tok, env, cwd):
    """A path string, or UNKNOWN when it depends on something we cannot see."""
    if tok == "~" or tok.startswith("~/"):
        tok = HOME + tok[1:]
    def sub(m):
        name = m.group(2) or m.group(3)
        if name in env:
            return env[name]
        if name == "HOME":
            return HOME
        raise KeyError(name)
    if "$(" in tok or "`" in tok:
        return UNKNOWN
    try:
        tok = VAR.sub(sub, tok)
    except KeyError:
        return UNKNOWN
    if "$" in tok:
        return UNKNOWN
    if tok.startswith("/"):
        return os.path.normpath(tok)  # an absolute path never depends on cwd
    if cwd is UNKNOWN:
        return UNKNOWN
    return os.path.normpath(os.path.join(cwd, tok))

WRAPPERS = {"command", "exec", "nohup", "time", "builtin", "nice", "stdbuf"}
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}"}
SHELLS = {"sh", "bash", "zsh", "dash"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def command_words(seg):
    """Strip assignments and wrappers; return (words, assignments)."""
    assigns, i = {}, 0
    while i < len(seg) and ASSIGN.match(seg[i]):
        k, v = seg[i].split("=", 1)
        assigns[k] = v
        i += 1
    words = seg[i:]
    while words:
        if words[0] in RESERVED:
            # `if cond; then git add`, `do rm x; done`, `{ git reset; }`, `! cmd`
            words = words[1:]
            continue
        base = os.path.basename(words[0])
        if base == "env":
            words = words[1:]
            while words and (words[0].startswith("-") or ASSIGN.match(words[0])):
                words = words[1:]
        elif base == "timeout":
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[2:] if words[0] in ("-s", "-k", "--signal", "--kill-after") else words[1:]
            words = words[1:]
        elif base == "test-slot":
            words = words[words.index("--") + 1:] if "--" in words else []
        elif base in WRAPPERS:
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[1:]
        elif base == "sudo":
            return [], assigns
        else:
            break
    return words, assigns

GIT_MUTATING = {"add", "rm", "mv", "commit", "restore", "reset", "checkout", "switch", "clean",
                "rebase", "cherry-pick", "revert", "am", "apply", "merge", "pull", "bisect",
                "update-index", "checkout-index", "read-tree", "sparse-checkout", "submodule",
                "merge-file"}
# The read-only verbs of the multi-verb subcommands above.
GIT_READONLY_VERBS = {"bisect": ("log", "view", "visualize", "terms", "help"),
                      "submodule": ("status", "summary"),
                      "sparse-checkout": ("list",)}
GIT_OPT_WITH_ARG = {"-c", "--namespace", "--exec-path", "--config-env", "--super-prefix", "--list-cmds"}

def git_target(args, cwd, env):
    """(subcommand, sub_args, target_dir_or_UNKNOWN)."""
    tgt, i = cwd, 0
    while i < len(args):
        a = args[i]
        if a == "-C" and i + 1 < len(args):
            tgt = expand(args[i + 1], env, tgt)  # UNKNOWN-safe
            i += 2
        elif a in ("--work-tree", "--git-dir") and i + 1 < len(args):
            if a == "--work-tree":
                tgt = expand(args[i + 1], env, tgt)
            i += 2
        elif a.startswith("--work-tree="):
            tgt = expand(a.split("=", 1)[1], env, tgt)
            i += 1
        elif a in GIT_OPT_WITH_ARG and i + 1 < len(args):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            return a, args[i + 1:], tgt
    return None, [], tgt

def git_is_write(sub, sargs):
    if sub not in GIT_MUTATING:
        return False
    s = set(sargs)
    if sub in ("merge", "pull") and "--ff-only" in s:
        return False
    if sub == "apply" and s & {"--check", "--stat", "--numstat", "--summary"} and not s & {"--apply", "--index", "--cached"}:
        return False
    # Dry-run flags are per subcommand: `-n` is --dry-run for add/rm/mv/clean,
    # but for commit it is --no-verify, a real commit. commit has only --dry-run.
    if sub in ("clean", "add", "rm", "mv") and s & {"-n", "--dry-run"}:
        return False
    if sub == "commit" and "--dry-run" in s:
        return False
    if sub in GIT_READONLY_VERBS and sargs[:1] and sargs[0] in GIT_READONLY_VERBS[sub]:
        return False
    return True

def nonopts(args, with_arg=()):
    out, i, ended = [], 0, False
    while i < len(args):
        a = args[i]
        if ended or not a.startswith("-") or a == "-":
            out.append(a)
        elif a == "--":
            ended = True
        elif a in with_arg:
            i += 1
        i += 1
    return out

def target_dir_opt(args, flag_short, flag_long):
    for i, a in enumerate(args):
        if a == flag_short and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(flag_long + "="):
            return a.split("=", 1)[1]
    return None

def shell_targets(words):
    """Path tokens a simple command writes (before expansion)."""
    base, args = os.path.basename(words[0]), words[1:]
    if base == "tee":
        return nonopts(args)
    if base == "sed":
        inplace = any(a == "--in-place" or a.startswith("--in-place=") or
                      (a.startswith("-") and not a.startswith("--") and "i" in a[1:].split("e")[0].split("f")[0])
                      for a in args)
        if not inplace:
            return []
        scripted = any(a in ("-e", "-f", "--expression", "--file") or a.startswith(("--expression=", "--file="))
                       for a in args)
        files = nonopts(args, with_arg=("-e", "-f", "--expression", "--file", "-l", "--line-length"))
        return files if scripted else files[1:]
    if base in ("cp", "ln", "install"):
        t = target_dir_opt(args, "-t", "--target-directory")
        if t:
            return [t]
        files = nonopts(args, with_arg=("-S", "-m", "-o", "-g", "--suffix"))
        if base == "install" and ("-d" in args or "--directory" in args):
            return files
        return files[-1:] if len(files) >= 2 else []
    if base == "mv":
        t = target_dir_opt(args, "-t", "--target-directory")
        files = nonopts(args, with_arg=("-S", "--suffix", "-t"))
        return files + ([t] if t else [])
    if base == "rm":
        return nonopts(args)  # no rm flag takes a value: -r and -d are switches
    if base == "touch":
        return nonopts(args, with_arg=("-d", "-r", "-t", "--reference", "--date"))
    if base == "truncate":
        return nonopts(args, with_arg=("-s", "-r", "--size", "--reference"))
    return []

def shell_c_script(args):
    """The script of `sh -c SCRIPT` (also `bash -lc`, `-ec`), else None."""
    for i, a in enumerate(args):
        if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
            return args[i + 1] if i + 1 < len(args) else None
        if not a.startswith("-"):
            return None
    return None

def git_output_targets(sub, sargs):
    """Files a git subcommand writes through an output option."""
    out = []
    for i, a in enumerate(sargs):
        nxt = sargs[i + 1] if i + 1 < len(sargs) else None
        if a.startswith(("--output=", "--output-directory=")):
            out.append(a.split("=", 1)[1])
        elif a in ("--output", "--output-directory") and nxt:
            out.append(nxt)
        elif a == "-o" and nxt and sub in ("archive", "format-patch"):
            out.append(nxt)
    return out

def check_bash(cmd, data, act, cwd=None, depth=0):
    try:
        toks = tokenize(cmd)
    except ValueError as e:
        log("unparsed", "%s: %s" % (e, cmd[:300]))
        return
    if cwd is None:
        cwd = os.path.realpath(data.get("cwd") or os.getcwd())
    env = {}
    segs, cur = [], []
    # A subshell's `cd` does not outlive it: `(` saves cwd, `)` restores it.
    for t in toks:
        if t[1] and t[0] in SEPS:
            if cur:
                segs.append(cur)
            cur = []
            if t[0] in ("(", ")"):
                segs.append(t[0])
        else:
            cur.append(t)
    if cur:
        segs.append(cur)
    stack, dirstack = [], []
    for seg in segs:
        if seg == "(":
            stack.append((cwd, dict(env)))
            continue
        if seg == ")":
            if stack:
                cwd, env = stack.pop()
            continue
        # Redirections first: pull them out of the word list. Only an
        # UNQUOTED operator token is a redirection.
        words, writes, i = [], [], 0
        while i < len(seg):
            t, is_op = seg[i]
            nxt = seg[i + 1] if i + 1 < len(seg) else None
            if is_op and t in REDIR_OUT:
                if nxt is not None and not nxt[1]:
                    writes.append(nxt[0])
                i += 2
                continue
            if is_op and t == ">&" and nxt is not None and not nxt[1] \
                    and not nxt[0].isdigit() and nxt[0] != "-":
                writes.append(nxt[0])  # `cmd >& file` redirects both streams to file
                i += 2
                continue
            if is_op:
                i += 2 if t in REDIR_SKIP else 1
                continue
            if t.isdigit() and nxt is not None and nxt[1] and (nxt[0] in REDIR_OUT or nxt[0] in REDIR_SKIP):
                i += 1
                continue
            words.append(t)
            i += 1
        words, assigns = command_words(words)
        if not words:
            env.update(assigns)
        elif words[0] == "export":
            for a in words[1:]:
                if ASSIGN.match(a):
                    k, v = a.split("=", 1)
                    env[k] = v
        base = os.path.basename(words[0]) if words else ""
        for w in writes:
            if w in ("/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"):
                continue
            p = expand(w, env, cwd)
            if p is UNKNOWN:
                log("unresolved", "redirect target %s in: %s" % (w, cmd[:300]))
                continue
            check_path(p, "the shell redirection `> %s`" % w, data, act)
        if base == "popd":
            cwd = dirstack.pop() if dirstack else UNKNOWN
            continue
        if base in ("cd", "pushd"):
            if base == "pushd":
                dirstack.append(cwd)
            cargs = words[1:]
            while cargs and cargs[0] in ("-P", "-L", "-e", "-@", "--"):
                cargs = cargs[1:]
            dest = cargs[0] if cargs else "~"
            if dest == "-":
                cwd = UNKNOWN
                continue
            nd = expand(dest, env, cwd)  # UNKNOWN-safe
            cwd = UNKNOWN if nd is UNKNOWN else os.path.realpath(nd)
            continue
        if base in SHELLS:
            script = shell_c_script(words[1:])
            if script is not None and depth < 3:
                check_bash(script, data, act, cwd, depth + 1)
            continue
        if base == "git":
            sub, sargs, tgt = git_target(words[1:], cwd, env)
            for w in git_output_targets(sub, sargs):
                p = expand(w, env, tgt)  # UNKNOWN-safe
                if p is UNKNOWN:
                    log("unresolved", "git %s output %s in: %s" % (sub, w, cmd[:300]))
                    continue
                check_path(p, "`git %s` output %s" % (sub, w), data, act)
            if sub and git_is_write(sub, sargs):
                if tgt is UNKNOWN:
                    log("unresolved", "git %s target in: %s" % (sub, cmd[:300]))
                    continue
                check_path(os.path.realpath(tgt), "`git %s`" % sub, data, act, honour_ignore=False)
            continue
        if base:
            for w in shell_targets(words):
                p = expand(w, env, cwd)
                if p is UNKNOWN:
                    log("unresolved", "%s target %s in: %s" % (base, w, cmd[:300]))
                    continue
                check_path(p, "`%s %s`" % (base, w), data, act)

def main():
    data = read_input()
    try:
        act = actor(data)
        if act is None:
            emit({})
        tool = data.get("tool_name")
        ti = data.get("tool_input") or {}
        if tool in ("Edit", "Write", "MultiEdit"):
            if ti.get("file_path"):
                check_path(ti["file_path"], "%s of %s" % (tool, ti["file_path"]), data, act)
        elif tool == "NotebookEdit":
            if ti.get("notebook_path"):
                check_path(ti["notebook_path"], "NotebookEdit of %s" % ti["notebook_path"], data, act)
        elif tool == "Bash":
            if isinstance(ti.get("command"), str):
                check_bash(ti["command"], data, act)
    except Unresolved as e:
        allow_warn("%s -- so this call was NOT checked for a main-checkout write. "
                   "Fix: repair git in this environment (the hook needs `git rev-parse` to classify the target)." % e)
    except Exception as e:  # a checker bug must never read as a silent allow
        allow_warn("the checker crashed (%s: %s), so this call was NOT checked for a main-checkout write. "
                   "Fix: reproduce with this call's stdin and fix ai/hooks/worktree-escape-guard.sh."
                   % (type(e).__name__, str(e)[:200]), kind="crashed")
    emit({})

main()
PYEOF
)

# A non-zero python3 exit (a crash before or outside main's own catch) must
# never read as a silent allow: log it and warn, still exit 0.
OUT=$(printf '%s' "${INPUT}" | python3 -c "${PY}" 2>/dev/null)
RC=$?
if [ "${RC}" -ne 0 ]; then
  WEG_LOG="${XDG_STATE_HOME:-${HOME}/.local/state}/athena/worktree-escape-guard.log"
  mkdir -p "$(dirname -- "${WEG_LOG}")" 2>/dev/null && \
    printf '%s\tcrashed\tpython3 exited %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RC}" >> "${WEG_LOG}" 2>/dev/null
  printf '%s\n' '{"systemMessage":"worktree-escape-guard: the checker crashed, so this tool call was NOT checked for a main-checkout write. Fix: reproduce with this call and fix ai/hooks/worktree-escape-guard.sh.","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"worktree-escape-guard crashed; this call was not checked. Fix: fix ai/hooks/worktree-escape-guard.sh."}}'
  exit 0
fi
printf '%s\n' "${OUT}"
exit 0
