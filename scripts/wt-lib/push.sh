#!/bin/bash
# push.sh - the one place wt pushes (DND-394).
# This file is meant to be sourced, not executed directly.
#
# By default wt pushes exactly as it always has: a plain `git push`, which runs
# under the owner's SSH key or credential helper. That is the owner's
# interactive use, and a human's push should be the human's.
#
# An agent driving wt sets the EXPLICIT signal WT_AGENT_PUSH=1. Then every push
# goes through the Athena forge wrapper for the remote's host, so the forge
# records the bot, not the owner:
#   github.com -> gh-athena git push ...   (athena-harness[bot])
#   gitlab.com -> glab-athena git push ... (athena-amby)
# Under the signal nothing falls back to a plain push. A remote no wrapper
# covers, a remote that does not resolve, a missing wrapper, or a wrapper
# refusal each FAIL, exit 3, with a Fix:. A Graphite submit (which pushes with
# the owner's credentials) is refused too.
#
# The signal is only ever the variable. No TTY or CI heuristic: an agent can
# have a TTY and a human can run without one.
#   unset, empty, 0 -> owner path (plain git push)
#   1               -> agent path (forge wrapper)
#   anything else   -> refused: a malformed signal is an error, not a guess.
#
# WT_ATHENA_BIN_DIR overrides where the wrappers are found (default: this
# checkout's ai/bin). It exists for the hermetic self-test
# (scripts/test/wt-agent-push/self-test.sh).

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

if [[ -z "${WT_LIB_PUSH_SOURCED:-}" ]]; then
    WT_LIB_PUSH_SOURCED="true"

    WT_LIB_PUSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    WT_AGENT_PUSH_ESCALATE='do not fall back to a plain `git push` and do not run any auth/login/refresh command; escalate to your admiral with the command, the error and the intent, and wait (athena:github -> "When a forge write can'\''t be done as Athena").'

    # _wt_push_refuse <message> : print a refusal with its Fix: and return 3.
    _wt_push_refuse() {
        echo "wt: REFUSING push as Athena: $1" >&2
        echo "  Fix: $2" >&2
        return 3
    }

    # wt_agent_push_mode : print `owner` or `agent`; refuse a malformed signal.
    wt_agent_push_mode() {
        case "${WT_AGENT_PUSH:-}" in
            ''|0) echo owner ;;
            1) echo agent ;;
            *) _wt_push_refuse "WT_AGENT_PUSH='${WT_AGENT_PUSH}' is not a recognised value." \
                   "set WT_AGENT_PUSH=1 when an agent drives wt, or unset it (or 0) for the owner's own push." ;;
        esac
    }

    # wt_push_url_host <url> : the lowercase host a git URL reaches, or empty
    # for a local path / file URL.
    wt_push_url_host() {
        local url="$1" rest=""
        case "$url" in
            file://*) ;;
            *://*)
                rest="${url#*://}"; rest="${rest%%/*}"; rest="${rest##*@}"; rest="${rest%%:*}" ;;
            /*|./*|../*) ;;
            *:*)
                # scp form [user@]host:path — a colon before any slash.
                rest="${url%%:*}"
                case "$rest" in */*) rest="" ;; *) rest="${rest##*@}" ;; esac ;;
        esac
        printf '%s' "$rest" | tr '[:upper:]' '[:lower:]'
    }

    # _wt_push_remote_arg <git push args...> : the repository argument (the
    # first positional). Refuses an option whose value is a separate word, so
    # the value is never mistaken for the remote.
    _wt_push_remote_arg() {
        local a
        for a in "$@"; do
            case "$a" in
                --) break ;;
                -o|--push-option|--repo|--receive-pack|--exec)
                    _wt_push_refuse "\`git push $*\`: the option $a takes a separate value, which wt does not parse." \
                        "pass it as $a=<value>, or push through the wrapper directly; $WT_AGENT_PUSH_ESCALATE"
                    return ;;
                -*) continue ;;
                *) printf '%s' "$a"; return 0 ;;
            esac
        done
        _wt_push_refuse "\`git push $*\` names no remote." \
            "wt always names the remote (e.g. \`origin\`); this is a wt bug — $WT_AGENT_PUSH_ESCALATE"
    }

    # wt_git_push <git push args...> : push as the owner (default) or, under
    # WT_AGENT_PUSH=1, through the forge wrapper for the remote's host.
    wt_git_push() {
        local mode
        mode="$(wt_agent_push_mode)" || return 3
        if [ "$mode" = owner ]; then
            git push "$@"
            return
        fi

        local remote urls url host wrapper="" w
        remote="$(_wt_push_remote_arg "$@")" || return 3
        urls="$(git remote get-url --push --all "$remote" 2>/dev/null)" || urls=""
        [ -n "$urls" ] || {
            _wt_push_refuse "the push URL of remote '$remote' in $(pwd) does not resolve, so wt cannot tell which forge wrapper to use." \
                "check \`git remote -v\` in that repo; if the remote is right, $WT_AGENT_PUSH_ESCALATE"
            return 3
        }
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            host="$(wt_push_url_host "$url")"
            case "$host" in
                github.com) w=gh-athena ;;
                gitlab.com) w=glab-athena ;;
                *)
                    _wt_push_refuse "remote '$remote' pushes to '$url' (host '${host:-none}'); only github.com (gh-athena) and gitlab.com (glab-athena) have an Athena push path." \
                        "an agent cannot push there as Athena; $WT_AGENT_PUSH_ESCALATE"
                    return 3 ;;
            esac
            if [ -n "$wrapper" ] && [ "$wrapper" != "$w" ]; then
                _wt_push_refuse "remote '$remote' has push URLs on more than one forge." \
                    "give the remote a single forge; $WT_AGENT_PUSH_ESCALATE"
                return 3
            fi
            wrapper="$w"
        done <<< "$urls"

        local bin_dir="${WT_ATHENA_BIN_DIR:-${WT_LIB_PUSH_DIR}/../../ai/bin}"
        [ -x "${bin_dir}/${wrapper}" ] || {
            _wt_push_refuse "the wrapper ${bin_dir}/${wrapper} is missing or not executable." \
                "run wt from a full ~/dev/custom checkout (scripts/ and ai/bin/ side by side); $WT_AGENT_PUSH_ESCALATE"
            return 3
        }

        local rc=0
        GIT_TERMINAL_PROMPT=0 "${bin_dir}/${wrapper}" git push "$@" || rc=$?
        if [ "$rc" -ne 0 ]; then
            _wt_push_refuse "\`${wrapper} git push $*\` failed (exit $rc); see its output above." \
                "if that output is a push rejection (non-fast-forward, stale lease), resolve it and re-run; otherwise $WT_AGENT_PUSH_ESCALATE"
            return 3
        fi
        return 0
    }

    # wt_refuse_gt_submit_under_agent : Graphite's `gt submit` pushes (and opens
    # PRs) with the owner's credentials, and wt cannot route it through a
    # wrapper. Under the agent signal it is refused; for the owner it passes.
    wt_refuse_gt_submit_under_agent() {
        local mode
        mode="$(wt_agent_push_mode)" || return 3
        [ "$mode" = owner ] && return 0
        _wt_push_refuse "Graphite \`gt submit\` pushes and opens PRs as the owner, and WT_AGENT_PUSH=1 is set." \
            "push each branch with \`wt\` commands that push through wt_git_push, or with \`GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git push -u origin <branch>\`, and open the PR with \`gh-athena pr create\`; $WT_AGENT_PUSH_ESCALATE"
    }
fi
