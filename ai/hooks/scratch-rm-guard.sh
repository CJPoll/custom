#!/bin/sh
# scratch-rm-guard.sh -- PreToolUse hook (matcher Bash): deny a delete BY
# PATTERN in a session scratchpad (DND-1653).
#
# WHY: the session scratchpad, /tmp/claude-<uid>/<project-slug>/<session>/
# scratchpad, is keyed on the session, not the agent. Every subagent a session
# fans out writes into ONE directory (ai/CLAUDE.md -> A shared scratch
# directory makes the wrong file look like your file). So a glob there matches
# files a sibling agent owns. Measured 2026-10-02 (DND-1621): the DND-1601
# captain's read-only reviewer ran `rm -f <scratchpad>/dnd-1601-*` to clean its
# probe files, and the glob deleted the captain's RUNNING gate log. DND-1621
# made test-slot restore its own output file and wrote the prose rule (delete
# scratch files by exact path). This hook enforces that rule.
#
# WHAT IS DENIED, for every session (the owner's included: the directory is
# shared whoever deletes):
#   * `rm` / `unlink` with an unquoted glob (`*`, `?`, `[`) that can match a
#     path in a scratchpad, at any depth (`**` included), or that can match a
#     scratchpad through a glob in a parent component.
#   * a RECURSIVE `rm` (-r, -R, --recursive) of a scratchpad itself or of a
#     directory above one (`rm -rf /tmp/claude-1000/<slug>/<session>`).
#   * `find` with `-delete`, or `-exec`/`-execdir`/`-ok`/`-okdir` running
#     rm/unlink/shred, whose start path is in, is, or is above a scratchpad.
#   * `xargs rm` in a pipeline fed by a `find` or a glob that reaches a
#     scratchpad (`find <sp> -name 'x-*' | xargs rm`, `ls <sp>/x-* | xargs rm`).
#   * `for v in <glob reaching a scratchpad>; do rm "$v"; done`: the loop
#     variable carries the glob.
#   * a glob delete whose path the hook CANNOT resolve (a variable it cannot
#     see, a command substitution, a relative path after an unresolvable
#     `cd`). An unresolved path is never read as "not a scratchpad"
#     (~/.claude/CLAUDE.md -> A failed lookup must never look like an empty
#     one). The Fix: says to spell the path literally.
#
# ALLOWED: an exact-path `rm` (recursive or not) of a file or subdirectory
# INSIDE a scratchpad; every delete outside the scratchpads; a quoted glob
# (`rm '<sp>/a*'` removes the file literally named `a*`); and text that only
# MENTIONS a delete: a quoted argument (`grep 'rm -f <sp>/*' f`), an `echo`, a
# commit message, a comment, a heredoc body fed to a non-shell. The command
# text is parsed as shell words, never matched as a string (the DND-786 class
# in git-stash-guard: denying read-only commands for quoted text).
#
# WHICH SCRATCHPADS: every path shaped <root>/claude-<uid>/<any>/<any>/
# scratchpad, for root /tmp, $TMPDIR and $CLAUDE_CODE_TMPDIR (each realpath'd;
# a symlinked prefix resolves). A structural match, so one session's guard
# protects every session's scratchpad, and no session id is computed (a key
# computed wrongly would match nothing and pass).
#
# PARSED: `;` `&&` `||` `|` `&` newlines, subshells, `$( )` and backticks (run
# as commands too), comments, heredocs (body is data, except when fed to
# sh/bash/zsh/dash with no script argument), `sh|bash|zsh|dash -c SCRIPT` and
# `eval` (recursively), `cd`/`pushd`/`popd`, VAR=value and export assignments,
# `$(mktemp ...)` (a path in $TMPDIR or /tmp), and these wrappers: env,
# timeout, nice, ionice, nohup, command, exec, builtin, setsid, time, stdbuf,
# sudo, doas, test-slot, xargs.
#
# NOT A SANDBOX. Not caught (examples, not an inventory): an interpreter
# (`python -c "shutil.rmtree(...)"`, `perl -e unlink`), `while read f; do rm
# "$f"; done < <(find ...)`, a wrapper not listed above, `git clean` in a repo
# under a scratchpad, and a glob qualifier `(N)`.
#
# FAILURE MODE: hot-loaded into every session. An input it cannot evaluate
# (non-JSON stdin, no python3, a checker crash) is ALLOWED with a visible
# systemMessage and a log line -- loud, never silent. Every deny and every
# unresolved/unparsed case is appended to
# ${XDG_STATE_HOME:-~/.local/state}/athena/scratch-rm-guard.log.
#
# --self-test runs ai/hooks/scratch-rm-guard.self-test.sh.

case "${1:-}" in
  --self-test)
    exec "$(dirname -- "$(realpath -- "$0")")/scratch-rm-guard.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
scratch-rm-guard.sh -- Claude Code PreToolUse hook (Bash).
Reads the hook JSON on stdin. Denies deleting by pattern in a session
scratchpad (/tmp/claude-<uid>/<slug>/<session>/scratchpad): a glob rm, a
recursive rm of the scratchpad or a directory above it, find -delete there,
and xargs rm fed from there. An exact-path rm of your own file passes.
  --self-test   run ai/hooks/scratch-rm-guard.self-test.sh
EOF
    exit 0 ;;
esac

INPUT=$(cat 2>/dev/null)

# Fast path, no python: a Bash command with no delete-shaped word cannot be
# denied. Every denied shape contains `rm`, `unlink` or `find` in its text
# (a `sh -c` script and an `eval` string included).
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "${INPUT}" | jq -r '.tool_name // empty' 2>/dev/null)
  if [ -n "${TOOL}" ] && [ "${TOOL}" != "Bash" ]; then
    exit 0
  fi
  if [ "${TOOL}" = "Bash" ]; then
    CMD=$(printf '%s' "${INPUT}" | jq -r '.tool_input.command // empty' 2>/dev/null)
    case "${CMD}" in
      *rm*|*unlink*|*find*) ;;
      *) exit 0 ;;
    esac
  fi
fi

SRG_LOG="${XDG_STATE_HOME:-${HOME}/.local/state}/athena/scratch-rm-guard.log"

if ! command -v python3 >/dev/null 2>&1; then
  mkdir -p "$(dirname -- "${SRG_LOG}")" 2>/dev/null && \
    printf '%s\tunchecked\tno python3 on PATH\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${SRG_LOG}" 2>/dev/null
  printf '%s\n' '{"systemMessage":"scratch-rm-guard: python3 is not on PATH, so this Bash call was NOT checked for a glob delete in a session scratchpad. Fix: install python3.","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"scratch-rm-guard could not run (no python3); this call was not checked. Fix: install python3."}}'
  exit 0
fi

PY=$(cat <<'PYEOF'
import fnmatch, json, os, re, sys, time

HOME = os.environ.get("HOME", "")
STATE = os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state")
LOG = os.path.join(STATE, "athena", "scratch-rm-guard.log")
WILD = object()          # a scratchpad path component that may be any name
UNKNOWN = object()       # a value the hook cannot see
MAX_DEPTH = 8            # nested sh -c / eval / $( ) levels

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
    emit({"systemMessage": "scratch-rm-guard: " + msg,
          "hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "additionalContext": "scratch-rm-guard could not check this call: " + msg}})

class Denied(Exception):
    pass

# ------------------------------------------------------------- scratchpads
def scratch_patterns():
    """Component lists, one per tmp root: <root>/claude-<uid>/*/*/scratchpad."""
    roots = ["/tmp"]
    for var in ("TMPDIR", "CLAUDE_CODE_TMPDIR"):
        v = os.environ.get(var)
        if v and v.startswith("/"):
            roots.append(v)
    pats, seen = [], set()
    for r in roots:
        rp = os.path.realpath(r)
        if rp in seen:
            continue
        seen.add(rp)
        pats.append([c for c in rp.split("/") if c] + ["claude-%d" % os.getuid(), WILD, WILD, "scratchpad"])
    return pats

PATTERNS = scratch_patterns()

GLOB_CHARS = re.compile(r"[*?\[]")
ESCAPED = re.compile(r"\[[^\]]\]")

def escape(s):
    """A literal string as an fnmatch pattern: each glob char becomes [c]."""
    return re.sub(r"([*?\[])", r"[\1]", s)

def unescape(s):
    return re.sub(r"\[([^\]])\]", r"\1", s)

def comp_is_glob(c):
    return c == "**" or bool(GLOB_CHARS.search(ESCAPED.sub("", c)))

class Unresolved(Exception):
    pass

def classify(pattern, cwd):
    """Where an fnmatch pattern path can land relative to the scratchpads:
    'reach' (a ** that can descend into one), 'inside', 'self', 'ancestor',
    or 'none'. Raises Unresolved for a relative path with no known cwd."""
    if not pattern.startswith("/"):
        if cwd is None:
            raise Unresolved("relative path %r with an unknown working directory" % unescape(pattern))
        pattern = escape(cwd) + "/" + pattern
    comps = [c for c in os.path.normpath(pattern).split("/") if c]
    # Resolve symlinks in the literal prefix. For a path with no glob, stop at
    # its parent: rm of a symlink removes the link, not what it points to.
    k = next((i for i, c in enumerate(comps) if comp_is_glob(c)), max(len(comps) - 1, 0))
    real = os.path.realpath("/" + "/".join(unescape(c) for c in comps[:k]))
    comps = [escape(c) for c in real.split("/") if c] + comps[k:]
    best = "none"
    order = ["none", "ancestor", "self", "inside", "reach"]
    for pat in PATTERNS:
        r = match(comps, pat)
        if order.index(r) > order.index(best):
            best = r
    return best

def match(comps, pat):
    for i, s in enumerate(pat):
        if i >= len(comps):
            return "ancestor"
        c = comps[i]
        if c == "**":
            return "reach"
        if s is WILD:
            continue
        if not fnmatch.fnmatchcase(s, c):
            return "none"
    return "self" if len(comps) == len(pat) else "inside"

# ---------------------------------------------------------------- tokenize
OPS = sorted(["&>>", "<<<", "<<-", ">>", "&>", ">|", ">&", "<&", "<<", "<>", "&&", "||", "|&",
              ";;", ";", "&", "|", "(", ")", "<", ">"], key=len, reverse=True)
SEPS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
PIPES = {"|", "|&"}
REDIRS = {">", ">>", ">|", "&>", "&>>", "<", "<>", ">&", "<&", "<<<", "<<", "<<-"}
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

def find_close(text, i, open_ch, close_ch):
    """Index of the close matching an already-open bracket; text[i] is the
    first char inside. Quotes are honoured. -1 if it never closes."""
    depth, n = 1, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                return -1
            i = j + 1
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

class Tok:
    __slots__ = ("kind", "value")
    def __init__(self, kind, value):
        self.kind, self.value = kind, value

def tokenize(text, heredocs=True):
    """[Tok]. kind 'op' (value: the operator), 'word' (value: segments), or
    'heredoc' (value: {'body': str}). A segment is ('lit', text, active),
    ('var', name, quoted), ('sub', script, quoted) or ('unk', why). An
    operator, a glob char (active) and a heredoc are recognised ONLY
    unquoted, so quoted text is data."""
    toks, segs, have, i, n = [], [], [False], 0, len(text)
    pending = []          # heredoc holders waiting for their body
    want = [None]         # the holder whose delimiter word is next

    def lit(s, active):
        if segs and segs[-1][0] == "lit" and segs[-1][2] == active:
            segs[-1] = ("lit", segs[-1][1] + s, active)
        else:
            segs.append(("lit", s, active))
        have[0] = True

    def flush():
        if have[0]:
            if not segs:
                segs.append(("lit", "", False))   # an empty quoted word: ""
            if want[0] is not None:
                want[0]["delim"] = "".join(s[1] for s in segs if s[0] == "lit")
                pending.append(want[0])
                want[0] = None
            else:
                toks.append(Tok("word", list(segs)))
        del segs[:]
        have[0] = False

    def dollar(i, quoted):
        """Parse a `$` expansion at text[i]; returns the index after it."""
        nxt = text[i + 1] if i + 1 < n else ""
        if text.startswith("$((", i):
            end = find_close(text, i + 3, "(", ")")
            end = find_close(text, end + 1, "(", ")") if end >= 0 else -1
            if end < 0:
                raise ValueError("unterminated $((")
            segs.append(("unk", "arithmetic")); have[0] = True
            return end + 1
        if nxt == "(":
            end = find_close(text, i + 2, "(", ")")
            if end < 0:
                raise ValueError("unterminated $(")
            segs.append(("sub", text[i + 2:end], quoted)); have[0] = True
            return end + 1
        if nxt == "{":
            end = text.find("}", i + 2)
            if end < 0:
                raise ValueError("unterminated ${")
            inner = text[i + 2:end]
            if NAME.fullmatch(inner):
                segs.append(("var", inner, quoted))
            else:
                segs.append(("unk", "${%s}" % inner))
            have[0] = True
            return end + 1
        m = NAME.match(text, i + 1)
        if m:
            segs.append(("var", m.group(0), quoted)); have[0] = True
            return m.end()
        if nxt and nxt in "@*#?$!-0123456789":
            segs.append(("unk", "$" + nxt)); have[0] = True
            return i + 2
        if nxt == "'" and not quoted:
            j = i + 2
            buf = []
            while j < n and text[j] != "'":
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1]); j += 2
                else:
                    buf.append(text[j]); j += 1
            if j >= n:
                raise ValueError("unterminated $'")
            lit("".join(buf), False)
            return j + 1
        lit("$", False)
        return i + 1

    while i < n:
        c = text[i]
        if c in " \t\r":
            flush(); i += 1
        elif c == "\n":
            flush(); toks.append(Tok("op", "\n")); i += 1
            while pending and i < n:
                h = pending[0]
                j = text.find("\n", i)
                line = text[i:j] if j >= 0 else text[i:]
                i = j + 1 if j >= 0 else n
                check = line.lstrip("\t") if h["strip"] else line
                if check == h["delim"]:
                    pending.pop(0)
                    h["closed"] = True
                else:
                    h["body"] += line + "\n"
        elif c == "#" and not have[0]:
            while i < n and text[i] != "\n":
                i += 1
        elif c == "\\":
            if i + 1 < n and text[i + 1] != "\n":
                lit(text[i + 1], False)
            i += 2
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ValueError("unterminated single quote")
            lit(text[i + 1:j], False); i = j + 1
        elif c == '"':
            have[0] = True
            j = i + 1
            while j < n and text[j] != '"':
                d = text[j]
                if d == "\\" and j + 1 < n:
                    lit(text[j + 1] if text[j + 1] in '"\\$`\n' else text[j:j + 2], False); j += 2
                elif d == "$":
                    j = dollar(j, True)
                elif d == "`":
                    end = text.find("`", j + 1)
                    if end < 0:
                        raise ValueError("unterminated backtick")
                    segs.append(("sub", text[j + 1:end], True)); j = end + 1
                else:
                    lit(d, False); j += 1
            if j >= n:
                raise ValueError("unterminated double quote")
            i = j + 1
        elif c == "$":
            i = dollar(i, False)
        elif c == "`":
            end = text.find("`", i + 1)
            if end < 0:
                raise ValueError("unterminated backtick")
            segs.append(("sub", text[i + 1:end], False)); have[0] = True; i = end + 1
        elif c == "(" and not have[0] and text.startswith("((", i):
            end = find_close(text, i + 2, "(", ")")
            end = find_close(text, end + 1, "(", ")") if end >= 0 else -1
            if end < 0:
                raise ValueError("unterminated ((")
            toks.append(Tok("op", ";")); i = end + 1
        elif c in ";&|()<>":
            # `2>` / `2>&1`: an all-digit word glued to a redirection is its fd.
            fd = have[0] and len(segs) == 1 and segs[0][0] == "lit" and segs[0][1].isdigit() and c in "<>"
            if fd:
                del segs[:]; have[0] = False
            flush()
            op = next(o for o in OPS if text.startswith(o, i))
            i += len(op)
            if op in ("<<", "<<-") and heredocs:
                holder = {"body": "", "delim": None, "strip": op == "<<-", "closed": False}
                toks.append(Tok("heredoc", holder))
                want[0] = holder   # the next word is the delimiter, quotes removed
                continue
            toks.append(Tok("op", op))
        else:
            lit(c, True); i += 1
    flush()
    if pending or want[0] is not None or any(t.kind == "heredoc" and not t.value["closed"] for t in toks):
        if heredocs:
            log("unparsed", "heredoc never closed; re-read with no heredocs: %s" % text[:300])
            return tokenize(text, heredocs=False)
    return toks

def split_commands(toks):
    """[(words, heredoc_bodies, sep_after)] simple commands."""
    cmds, words, bodies, skip = [], [], [], False
    for t in toks:
        if t.kind == "heredoc":
            bodies.append(t.value["body"])
            continue
        if t.kind == "op":
            if t.value in SEPS:
                if words or bodies:
                    cmds.append((words, bodies, t.value))
                words, bodies, skip = [], [], False
            elif t.value in REDIRS:
                skip = True   # the next word is a redirection target, not an argument
            continue
        if skip:
            skip = False
            continue
        words.append(t.value)
    if words or bodies:
        cmds.append((words, bodies, None))
    return cmds

# ---------------------------------------------------------------- evaluate
class Tainted:
    """A loop variable bound to a glob that reaches a scratchpad."""
    def __init__(self, pattern):
        self.pattern = pattern

def var_value(name, env, cwd):
    if name == "PWD":
        return cwd if cwd is not None else UNKNOWN
    if name in env:
        return env[name]
    if name in os.environ:
        return os.environ[name]
    return UNKNOWN

def mktemp_path(script):
    """`$(mktemp [opts])` with no directory option: a path in $TMPDIR or /tmp."""
    try:
        cmds = split_commands(tokenize(script))
    except ValueError:
        return None
    if len(cmds) != 1 or not cmds[0][0]:
        return None
    words = [plain(w, {}, None) for w in cmds[0][0]]
    if words[0] != "mktemp" or any(w is None for w in words):
        return None
    for w in words[1:]:
        if w.startswith("-p") or w.startswith("--tmpdir") or "/" in w:
            return None
    return (os.environ.get("TMPDIR") or "/tmp").rstrip("/") + "/mktemp-unknown-name"

def resolve(segs, env, cwd):
    """(pattern or None, has_glob). The pattern escapes every glob char that
    was quoted, so only an active one matches as a glob."""
    parts, glob, unknown = [], False, False
    for idx, s in enumerate(segs):
        kind = s[0]
        if kind == "lit":
            text, active = s[1], s[2]
            if active and idx == 0 and (text == "~" or text.startswith("~/")):
                parts.append(escape(HOME)); text = text[1:]
            if active:
                parts.append(text)
                glob = glob or bool(GLOB_CHARS.search(text))
            else:
                parts.append(escape(text))
        elif kind == "var":
            v = var_value(s[1], env, cwd)
            if isinstance(v, Tainted):
                parts.append(v.pattern); glob = True
            elif v is UNKNOWN:
                unknown = True
            elif s[2]:
                parts.append(escape(v))
            else:
                parts.append(v)
                glob = glob or bool(GLOB_CHARS.search(v))
        elif kind == "sub":
            p = mktemp_path(s[1])
            if p is None:
                unknown = True
            else:
                parts.append(escape(p))
        else:
            unknown = True
    return (None if unknown else "".join(parts)), glob

def plain(segs, env, cwd):
    """The word's string value, or None when any part is unknown."""
    pat, _ = resolve(segs, env, cwd)
    return None if pat is None else unescape(pat)

def is_lit(segs, value=None):
    ok = bool(segs) and all(s[0] == "lit" for s in segs)
    return ok and (value is None or "".join(s[1] for s in segs) == value)

RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}"}
SHELLS = {"sh", "bash", "zsh", "dash"}
# wrapper -> (short options taking a value, long options taking a value)
WRAPPERS = {
    "env": ("uCS", {"--unset", "--chdir", "--split-string"}),
    "timeout": ("sk", {"--signal", "--kill-after"}),
    "nice": ("n", {"--adjustment"}),
    "ionice": ("cnp", {"--class", "--classdata", "--pid"}),
    "nohup": ("", set()),
    "command": ("", set()),
    "exec": ("a", set()),
    "builtin": ("", set()),
    "setsid": ("", set()),
    "time": ("of", {"--output", "--format"}),
    "stdbuf": ("ioe", {"--input", "--output", "--error"}),
    "sudo": ("uUgCDprRtTh", {"--user", "--other-user", "--group", "--close-from", "--chdir",
                             "--prompt", "--chroot", "--role", "--type", "--command-timeout", "--host"}),
    "doas": ("uC", set()),
    "test-slot": ("", {"--label", "--wait-timeout", "--outcome-file", "--weight", "--pool"}),
    "xargs": ("adEILnPs", {"--arg-file", "--delimiter", "--eof", "--replace", "--max-lines",
                            "--max-args", "--max-procs", "--max-chars", "--process-slot-var"}),
}

def strip_options(words, env, cwd, short_val, long_val):
    """Skip leading options; returns (rest, {option: value})."""
    opts = {}
    while words:
        w = plain(words[0], env, cwd)
        if w is None or not w.startswith("-") or w == "-":
            return words, opts
        if w == "--":
            return words[1:], opts
        if w.startswith("--"):
            name, eq, val = w.partition("=")
            if name in long_val and not eq:
                opts[name] = plain(words[1], env, cwd) if len(words) > 1 else None
                words = words[2:]
            else:
                opts[name] = val if eq else None
                words = words[1:]
            continue
        cluster, words = w[1:], words[1:]
        for j, c in enumerate(cluster):
            if c in short_val:
                rest = cluster[j + 1:]
                if rest:
                    opts["-" + c] = rest
                else:
                    opts["-" + c] = plain(words[0], env, cwd) if words else None
                    words = words[1:]
                break
            opts["-" + c] = None
    return words, opts

class State:
    def __init__(self, env, cwd, depth):
        self.env, self.cwd, self.depth = env, cwd, depth
        self.pipe_source = None   # a description, while the current pipeline is fed from a scratchpad

def chdir(st, segs):
    if segs is None:
        st.cwd = HOME or None
        return
    p = plain(segs, st.env, st.cwd)
    if p is None or p == "-":
        st.cwd = None
        return
    if p.startswith("~"):
        p = HOME + p[1:]
    if not p.startswith("/"):
        if st.cwd is None:
            return
        p = os.path.join(st.cwd, p)
    st.cwd = os.path.realpath(p)

def deny_glob(tool, shown, why):
    raise Denied(
        "scratch-rm-guard: `%s` deletes by pattern (%s) in a session scratchpad. %s The scratchpad "
        "(/tmp/claude-<uid>/<project>/<session>/scratchpad) is keyed on the SESSION, not the agent, so "
        "every agent of the session writes into it and a pattern matches files a sibling agent still "
        "uses (DND-1621: a reviewer's `rm -f <scratchpad>/dnd-1601-*` deleted its captain's running gate "
        "log). Fix: delete each file you wrote by its exact path (`rm -f <scratchpad>/dnd-<N>-a.log "
        "<scratchpad>/dnd-<N>-b.log`); or keep your scratch files in a per-mission subdirectory "
        "(<scratchpad>/dnd-<N>/) and remove that directory by its exact path (`rm -rf "
        "<scratchpad>/dnd-<N>`). If you did not write a file, leave it." % (tool, shown, why))

def deny_unresolved(tool, why):
    raise Denied(
        "scratch-rm-guard: `%s` deletes by pattern and the hook could not resolve where (%s), so it "
        "cannot rule out a session scratchpad, which every agent of the session shares (DND-1621: a "
        "glob there deleted a sibling's running gate log). An unresolved path is never read as \"not "
        "the scratchpad\". Fix: spell the directory literally (an absolute path, or a variable assigned "
        "in this same command), or delete each file by its exact path." % (tool, why))

def show(pat):
    return "`%s`" % unescape(pat) if pat is not None else "an unresolved path"

def reaches(pat, glob, st, recursive):
    """True when a delete of this pattern can remove a scratchpad file that
    was not named exactly."""
    res = classify(pat, st.cwd)
    if res == "reach":
        return True
    if res == "inside":
        return glob
    if res in ("self", "ancestor"):
        return recursive
    return False

def check_rm(tool, args, st):
    words, opts = strip_options(args, st.env, st.cwd, "", set())
    recursive = any(k in opts for k in ("-r", "-R", "--recursive"))
    for w in words:
        pat, glob = resolve(w, st.env, st.cwd)
        try:
            if pat is None:
                raise Unresolved("a variable or command substitution the hook cannot see")
            if reaches(pat, glob, st, recursive):
                deny_glob(tool, show(pat), "A glob, or a recursive delete of the scratchpad or a "
                          "directory above it, removes files by pattern rather than by name.")
        except Unresolved as e:
            if glob:
                deny_unresolved(tool, str(e))
            if recursive:
                log("unresolved", "%s -r target: %s" % (tool, e))

FIND_ACTIONS = {"-exec", "-execdir", "-ok", "-okdir"}
DELETERS = {"rm", "unlink", "shred"}

def find_starts(args, st):
    """(start path words, deletes?)"""
    words = list(args)
    while words and is_lit(words[0]) and plain(words[0], {}, None) in ("-H", "-L", "-P"):
        words = words[1:]
    starts = []
    while words:
        v = plain(words[0], st.env, st.cwd)
        if v is not None and (v.startswith("-") or v in ("(", "!", ")")):
            break
        starts.append(words[0]); words = words[1:]
    deletes = False
    for i, w in enumerate(words):
        v = plain(w, st.env, st.cwd)
        if v == "-delete":
            deletes = True
        elif v in FIND_ACTIONS and i + 1 < len(words):
            nv = plain(words[i + 1], st.env, st.cwd)
            if nv is not None and os.path.basename(nv) in DELETERS:
                deletes = True
    return starts or [[("lit", ".", False)]], deletes

def find_reaches(starts, st):
    """A description of the first start path in, at or above a scratchpad,
    None when none is; raises Unresolved."""
    for w in starts:
        pat, _ = resolve(w, st.env, st.cwd)
        if pat is None:
            raise Unresolved("a find start path the hook cannot see")
        if classify(pat, st.cwd) != "none":
            return show(pat)
    return None

def check_find(args, st):
    starts, deletes = find_starts(args, st)
    try:
        hit = find_reaches(starts, st)
    except Unresolved as e:
        if deletes:
            deny_unresolved("find", str(e))
        return
    if hit and deletes:
        deny_glob("find", "start path %s" % hit, "find deletes every match under its start path.")
    if hit:
        st.pipe_source = "find from %s" % hit

def note_glob_source(words, st):
    """A pipeline stage that lists scratchpad files by glob (`ls <sp>/x-*`)."""
    for w in words:
        pat, glob = resolve(w, st.env, st.cwd)
        if pat is None or not glob:
            continue
        try:
            if classify(pat, st.cwd) != "none":
                st.pipe_source = "a glob %s" % show(pat)
        except Unresolved:
            pass

def run_script(script, st, label):
    if st.depth >= MAX_DEPTH:
        log("unparsed", "nesting deeper than %d: %s" % (MAX_DEPTH, script[:300]))
        return
    inner = State(dict(st.env), st.cwd, st.depth + 1)
    check_text(script, inner)

def check_command(words, bodies, st):
    # assignments
    while words and words[0][0][0] == "lit" and words[0][0][2]:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", words[0][0][1])
        if not m:
            break
        rest = [("lit", words[0][0][1][m.end():], words[0][0][2])] + list(words[0][1:])
        v = plain(rest, st.env, st.cwd)
        st.env[m.group(1)] = UNKNOWN if v is None else v
        words = words[1:]
    while words and is_lit(words[0]) and plain(words[0], {}, None) in RESERVED:
        words = words[1:]
    if not words:
        return
    head = plain(words[0], st.env, st.cwd)
    if head == "for" and len(words) >= 3 and plain(words[2], {}, None) == "in":
        name = plain(words[1], {}, None)
        st.env[name] = UNKNOWN
        for w in words[3:]:
            pat, glob = resolve(w, st.env, st.cwd)
            if pat is not None and glob:
                try:
                    if classify(pat, st.cwd) != "none":
                        st.env[name] = Tainted(pat)
                except Unresolved:
                    pass
        return
    # wrappers
    while head is not None and os.path.basename(head) in WRAPPERS:
        base = os.path.basename(head)
        words, opts = strip_options(words[1:], st.env, st.cwd, *WRAPPERS[base])
        if base == "command" and ("-v" in opts or "-V" in opts):
            return
        if base == "env":
            if opts.get("-C") or opts.get("--chdir"):
                chdir(st, [("lit", opts.get("-C") or opts.get("--chdir"), False)])
            split = opts.get("-S") or opts.get("--split-string")
            if split:
                try:
                    pre = [t.value for t in tokenize(split) if t.kind == "word"]
                except ValueError:
                    pre = []
                words = pre + words
            while words and words[0][0][0] == "lit" and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0][0][1]):
                words = words[1:]
        elif base == "sudo" and (opts.get("-D") or opts.get("--chdir")):
            chdir(st, [("lit", opts.get("-D") or opts.get("--chdir"), False)])
        elif base == "timeout":
            words = words[1:]
        elif base == "xargs":
            if not words:
                return
            nxt = plain(words[0], st.env, st.cwd)
            if nxt is not None and os.path.basename(nxt) in DELETERS and st.pipe_source:
                deny_glob("xargs %s" % os.path.basename(nxt), "names from %s" % st.pipe_source,
                          "xargs deletes every name the pipeline lists.")
        if not words:
            return
        head = plain(words[0], st.env, st.cwd)
    if head is None:
        return
    base = os.path.basename(head)
    args = words[1:]
    if base in ("export", "declare", "typeset", "local", "readonly"):
        for w in args:
            if w and w[0][0] == "lit":
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", w[0][1])
                if m:
                    v = plain([("lit", w[0][1][m.end():], w[0][2])] + list(w[1:]), st.env, st.cwd)
                    st.env[m.group(1)] = UNKNOWN if v is None else v
    elif base in ("cd", "pushd"):
        chdir(st, args[0] if args else None)
    elif base == "popd":
        st.cwd = None
    elif base in ("rm", "unlink"):
        check_rm(base, args, st)
    elif base == "find":
        check_find(args, st)
    elif base in SHELLS:
        script, has_c, rest = None, False, list(args)
        while rest:
            v = plain(rest[0], st.env, st.cwd)
            if v is None or not (v.startswith("-") or v.startswith("+")):
                break
            rest = rest[1:]
            if v in ("-o", "+o", "-O", "+O"):
                rest = rest[1:]
            elif "c" in v[1:] and not v.startswith("--"):
                has_c = True
        if has_c:
            if rest:
                script = plain(rest[0], st.env, st.cwd)
                if script is None:
                    log("unparsed", "%s -c script the hook cannot see" % base)
        elif not rest and bodies:
            script = "".join(bodies)
        if script:
            run_script(script, st, base)
    elif base == "eval":
        parts = [plain(w, st.env, st.cwd) for w in args]
        if any(p is None for p in parts):
            log("unparsed", "eval of a word the hook cannot see")
        else:
            run_script(" ".join(parts), st, "eval")
    else:
        note_glob_source(args, st)

def subs_of(words):
    for w in words:
        for s in w:
            if s[0] == "sub":
                yield s[1]

def check_text(text, st):
    try:
        toks = tokenize(text)
    except ValueError as e:
        log("unparsed", "%s: %s" % (e, text[:300]))
        return
    for words, bodies, sep in split_commands(toks):
        for script in subs_of(words):
            run_script(script, st, "$( )")
        check_command(words, bodies, st)
        if sep not in PIPES:
            st.pipe_source = None

def main():
    raw = sys.stdin.read()
    if not raw.strip():
        log("unchecked", "empty stdin")
        emit({})
    try:
        data = json.loads(raw)
    except ValueError:
        allow_warn("stdin was not JSON, so this Bash call was NOT checked for a glob delete in a session "
                   "scratchpad. Fix: this is a Claude Code hook-contract change; update ai/hooks/scratch-rm-guard.sh.")
    if not isinstance(data, dict):
        allow_warn("stdin was not a JSON object; this call was NOT checked. "
                   "Fix: update ai/hooks/scratch-rm-guard.sh to the current hook contract.")
    if data.get("tool_name") != "Bash":
        emit({})
    cmd = (data.get("tool_input") or {}).get("command")
    if not isinstance(cmd, str):
        allow_warn("the Bash call carried no command string, so it was NOT checked. "
                   "Fix: update ai/hooks/scratch-rm-guard.sh to the current hook contract.")
    cwd = data.get("cwd")
    cwd = os.path.realpath(cwd) if isinstance(cwd, str) and cwd.startswith("/") else None
    try:
        check_text(cmd, State({}, cwd, 0))
    except Denied as d:
        log("deny", "agent=%s %s" % (data.get("agent_id") or "-", cmd[:400]))
        emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                     "permissionDecisionReason": str(d)}})
    except Exception as e:  # a checker bug must never read as a silent allow
        allow_warn("the checker crashed (%s: %s), so this call was NOT checked for a glob delete in a "
                   "session scratchpad. Fix: reproduce with this call's stdin and fix "
                   "ai/hooks/scratch-rm-guard.sh." % (type(e).__name__, str(e)[:200]), kind="crashed")
    emit({})

main()
PYEOF
)

# A non-zero python3 exit (a crash outside main's own catch) must never read
# as a silent allow: log it and warn, still exit 0.
OUT=$(printf '%s' "${INPUT}" | python3 -c "${PY}" 2>/dev/null)
RC=$?
if [ "${RC}" -ne 0 ]; then
  mkdir -p "$(dirname -- "${SRG_LOG}")" 2>/dev/null && \
    printf '%s\tcrashed\tpython3 exited %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RC}" >> "${SRG_LOG}" 2>/dev/null
  printf '%s\n' '{"systemMessage":"scratch-rm-guard: the checker crashed, so this Bash call was NOT checked for a glob delete in a session scratchpad. Fix: reproduce with this call and fix ai/hooks/scratch-rm-guard.sh.","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"scratch-rm-guard crashed; this call was not checked. Fix: fix ai/hooks/scratch-rm-guard.sh."}}'
  exit 0
fi
printf '%s\n' "${OUT}"
exit 0
