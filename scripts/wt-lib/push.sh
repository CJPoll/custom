#!/bin/bash
# push.sh - the one place wt pushes (DND-394) and pulls (wt_git_pull, DND-1977).
# This file is meant to be sourced, not executed directly.
#
# By default wt pushes exactly as it always has: a plain `git push`, which runs
# under the owner's SSH key or credential helper. That is the owner's
# interactive use, and a human's push should be the human's.
#
# An agent driving wt sets the EXPLICIT signal WT_AGENT_PUSH=1. Then every push
# goes through ai/bin/forge-push, which runs the Athena forge wrapper for the
# remote's host (forge-git's host table, DND-1995), so the forge records the
# bot, not the owner:
#   github.com -> gh-athena git push ...   (athena-harness[bot])
#   gitlab.com -> glab-athena git push ... (the bot of the project namespace)
# Under the signal nothing falls back to a plain push. A remote no wrapper
# covers, a remote that does not resolve, a missing forge-push, or a wrapper
# refusal each FAIL, exit 3, with a Fix:. A Graphite submit (which pushes with
# the owner's credentials) is refused too: Graphite has no Athena route (see
# wt_refuse_gt_submit_under_agent), so agents stack with plain branches and
# `gh-athena pr create --base <parent-branch>`.
#
# The signal is only ever the variable. No TTY or CI heuristic: an agent can
# have a TTY and a human can run without one.
#   unset, empty, 0 -> owner path (plain git push)
#   1               -> agent path (forge wrapper)
#   anything else   -> refused: a malformed signal is an error, not a guess.
#
# WT_ATHENA_BIN_DIR overrides where forge-push and forge-git are found
# (default: this checkout's ai/bin). It exists for the hermetic self-test
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

    # wt_git_push <git push args...> : push as the owner (default) or, under
    # WT_AGENT_PUSH=1, through ai/bin/forge-push, which picks the forge
    # wrapper for the remote's host from forge-git's table (DND-1995; wt kept
    # its own copy of that table before). forge-push refuses an unknown host,
    # a local path, an unresolvable remote and push URLs on two forges; wt
    # turns any non-zero exit into its own loud refusal, never a plain push.
    wt_git_push() {
        local mode
        mode="$(wt_agent_push_mode)" || return 3
        if [ "$mode" = owner ]; then
            git push "$@"
            return
        fi

        local bin_dir="${WT_ATHENA_BIN_DIR:-${WT_LIB_PUSH_DIR}/../../ai/bin}"
        [ -x "${bin_dir}/forge-push" ] || {
            _wt_push_refuse "${bin_dir}/forge-push is missing or not executable." \
                "run wt from a full ~/dev/custom checkout (scripts/ and ai/bin/ side by side); $WT_AGENT_PUSH_ESCALATE"
            return 3
        }

        local rc=0
        GIT_TERMINAL_PROMPT=0 "${bin_dir}/forge-push" -C "$(pwd)" "$@" || rc=$?
        if [ "$rc" -ne 0 ]; then
            _wt_push_refuse "\`forge-push -C $(pwd) $*\` failed (exit $rc); see its output above." \
                "if that output is a push rejection (non-fast-forward, stale lease), resolve it and re-run; if it is a refused remote, follow its Fix:; otherwise $WT_AGENT_PUSH_ESCALATE"
            return 3
        fi
        return 0
    }

    # wt_git_pull <git pull args...> : pull in the current directory as the
    # owner (default, plain git pull) or, under WT_AGENT_PUSH=1, through
    # ai/bin/forge-git, so an agent's read of the remote rides Athena's forge
    # route and never the owner's SSH key (DND-1977).
    wt_git_pull() {
        local mode
        mode="$(wt_agent_push_mode)" || return 3
        if [ "$mode" = owner ]; then
            git pull "$@"
            return
        fi
        local bin_dir="${WT_ATHENA_BIN_DIR:-${WT_LIB_PUSH_DIR}/../../ai/bin}"
        [ -x "${bin_dir}/forge-git" ] || {
            _wt_push_refuse "${bin_dir}/forge-git is missing or not executable." \
                "run wt from a full ~/dev/custom checkout (scripts/ and ai/bin/ side by side); $WT_AGENT_PUSH_ESCALATE"
            return 3
        }
        "${bin_dir}/forge-git" -C "$(pwd)" pull "$@"
    }

    # wt_refuse_gt_submit_under_agent : Graphite's `gt submit` pushes (and opens
    # PRs) with the owner's credentials. Under the agent signal it is refused;
    # for the owner it passes.
    #
    # There is no Athena route through Graphite (DND-399, researched on gt
    # 1.7.2). `gt submit` first requires the Graphite auth token stored in the
    # owner's ~/.config/graphite/user_config; no env var or flag supplies one.
    # It then opens every PR by POSTing to api.graphite.dev
    # (/v1/graphite/submit/pull-requests), whose params carry no GitHub token:
    # Graphite's own GitHub App opens the PR for the Graphite user, i.e. the
    # owner. Only its branch push shells out to `git push`. A bot identity
    # (athena-harness[bot] is a GitHub App) cannot sign in to Graphite, and
    # Graphite does not support GitLab at all. So agents stack with plain
    # branches instead: push each through the wrapper and open each PR with
    # `gh-athena pr create --base <parent-branch>`.
    wt_refuse_gt_submit_under_agent() {
        local mode
        mode="$(wt_agent_push_mode)" || return 3
        [ "$mode" = owner ] && return 0
        _wt_push_refuse "Graphite \`gt submit\` pushes and opens PRs as the owner, and WT_AGENT_PUSH=1 is set. Graphite has no Athena route: it needs the owner's stored Graphite token, and api.graphite.dev opens the PRs as the owner." \
            "do not use Graphite stacks as an agent. Use plain branches: push each with \`wt\` commands that push through wt_git_push, or with \`GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git push -u origin <branch>\`, then open each PR with \`~/dev/custom/ai/bin/gh-athena pr create --base <parent-branch>\` (the parent is the trunk for the bottom branch). On GitLab use \`glab-athena git push\` and \`glab-athena mr create --target-branch <parent-branch>\`. If that path fails, $WT_AGENT_PUSH_ESCALATE"
    }
fi
