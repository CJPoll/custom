# initd-proc-tree.sh -- find and end the WHOLE process tree of one OpenRC
# service instance (DND-812). Sourced by the system-files/*.initd scripts; POSIX
# sh, no bashisms (openrc-run runs the service script under /bin/sh).
#
# Installed (copied, root-owned, never symlinked: root sources it) to
#   /usr/local/lib/athena/initd-proc-tree.sh
# and overridable per service with ATHENA_PROC_TREE_LIB in /etc/conf.d/<svc>.
#
# Why: supervise-daemon (and start-stop-daemon) signal ONE pid on stop. A
# supervised command that forks long-lived children (run.sh -> run-helper.sh ->
# Runner.Listener; dockerd-rootless.sh -> rootlesskit -> dockerd) leaves them
# re-parented to PID 1, still running. A "stopped" GitHub runner kept taking
# jobs that way.
#
# How a process is judged part of instance TAG's tree. ALL of:
#   - its real uid is UID (the service's command_user);
#   - it is not a zombie, not this shell, and not an ancestor of this shell;
#   - ONE of:
#       * its initial environment holds the exact entry ATHENA_SVC_TREE=TAG.
#         The initd passes that ONLY to its command, via
#         `supervise_daemon_args="--env ATHENA_SVC_TREE=${RC_SVCNAME}"`, and
#         every descendant inherits it. The openrc-run process doing the stop
#         never carries it, so the stop side cannot match itself. (RC_SVCNAME
#         would NOT do: openrc-run carries RC_SVCNAME too.)
#       * its executable or working directory is an ANCHOR or lies under it
#         (ANCHOR/...). The anchor is compared as a whole path component, so
#         /x/actions-runner never matches /x/actions-runner-2. This catches
#         processes started before the tag existed, e.g. orphans already
#         running when this fix is installed.
# Nothing here matches on argv text, so a scanner can never match its own
# command line (the `pgrep -f` self-match class).
#
# Functions:
#   proc_tree_pids TAG UID [ANCHOR...]         print matching pids, one per line
#   proc_tree_reap TAG UID TIMEOUT [ANCHOR...] SIGTERM the tree, wait TIMEOUT
#       seconds, SIGKILL survivors, then ASSERT nothing matches.
#       Exit 0: nothing left. 1: something survived SIGKILL (printed, Fix:).
#       2: malformed input (Fix:). A malformed key is an error, never an empty
#       match: an empty UID (a failed `id -u`) must not read as "no processes".

_pt_say() { # level message
	case "$1" in
	err) if command -v eerror >/dev/null 2>&1; then eerror "$2"; else printf '%s\n' "$2" >&2; fi ;;
	*) if command -v einfo >/dev/null 2>&1; then einfo "$2"; else printf '%s\n' "$2" >&2; fi ;;
	esac
}

# _pt_validate TAG UID TIMEOUT [ANCHOR...]; sets _pt_anchors (newline list,
# trailing slashes stripped). Returns 2 with a Fix: on any malformed input.
_pt_validate() {
	_pt_tag="$1"; _pt_uid="$2"; _pt_timeout="$3"; shift 3
	case "${_pt_tag}" in
	'' | *[!A-Za-z0-9._@:+-]*)
		_pt_say err "initd-proc-tree: bad instance tag '${_pt_tag}'. Fix: pass the service's RC_SVCNAME (letters, digits, . _ @ : + - only)."
		return 2 ;;
	esac
	case "${_pt_uid}" in
	'' | *[!0-9]*)
		_pt_say err "initd-proc-tree: bad uid '${_pt_uid}' for ${_pt_tag}. Fix: the service user must exist; check \`id -u <user>\` and the user set in /etc/conf.d/${_pt_tag}."
		return 2 ;;
	esac
	case "${_pt_timeout}" in
	'' | *[!0-9]*)
		_pt_say err "initd-proc-tree: bad timeout '${_pt_timeout}' for ${_pt_tag}. Fix: set ATHENA_PROC_TREE_TIMEOUT to a whole number of seconds."
		return 2 ;;
	esac
	_pt_anchors=""
	for _pt_a in "$@"; do
		while :; do
			case "${_pt_a}" in
			?*/) _pt_a="${_pt_a%/}" ;;
			*) break ;;
			esac
		done
		case "${_pt_a}" in
		/?*) ;;
		*)
			_pt_say err "initd-proc-tree: bad anchor '${_pt_a}' for ${_pt_tag}. Fix: an anchor must be an absolute path other than /, such as the instance's RUNNER_DIR."
			return 2 ;;
		esac
		_pt_anchors="${_pt_anchors}${_pt_a}
"
	done
	return 0
}

# _pt_status PID: sets _pt_s_uid _pt_s_ppid _pt_s_state from /proc/PID/status.
_pt_status() {
	_pt_s_uid=""; _pt_s_ppid=""; _pt_s_state=""
	[ -r "/proc/$1/status" ] || return 1
	while IFS= read -r _pt_line; do
		case "${_pt_line}" in
		State:*) set -- ${_pt_line#State:}; _pt_s_state="$1" ;;
		PPid:*) set -- ${_pt_line#PPid:}; _pt_s_ppid="$1" ;;
		Uid:*) set -- ${_pt_line#Uid:}; _pt_s_uid="$1" ;;
		esac
	done < "/proc/$1/status" 2>/dev/null || return 1
	[ -n "${_pt_s_uid}" ]
}

# _pt_under PATH: PATH equals, or lies under, one of _pt_anchors.
_pt_under() {
	[ -n "$1" ] || return 1
	_pt_p="${1% (deleted)}"
	_pt_ifs="${IFS}"; IFS='
'
	for _pt_a in ${_pt_anchors}; do
		case "${_pt_p}" in
		"${_pt_a}" | "${_pt_a}"/*) IFS="${_pt_ifs}"; return 0 ;;
		esac
	done
	IFS="${_pt_ifs}"
	return 1
}

# _pt_scan: prints matching pids. Runs in a subshell that has cd'd to / so no
# process this scan forks can sit under an anchor.
_pt_scan() {
	(
		cd / || exit 2
		# /proc/self, opened by the shell's own redirection, is this subshell.
		read -r _pt_self _pt_rest < /proc/self/stat || exit 2
		_pt_skip=" ${_pt_self} "
		_pt_p="${_pt_self}"
		while [ -n "${_pt_p}" ] && [ "${_pt_p}" != 0 ]; do
			_pt_status "${_pt_p}" || break
			_pt_skip="${_pt_skip}${_pt_s_ppid} "
			_pt_p="${_pt_s_ppid}"
		done
		_pt_n=0
		for _pt_d in /proc/[0-9]*; do
			_pt_pid="${_pt_d#/proc/}"
			case "${_pt_skip}" in *" ${_pt_pid} "*) continue ;; esac
			_pt_status "${_pt_pid}" || continue
			_pt_n=$((_pt_n + 1))
			[ "${_pt_s_uid}" = "${_pt_uid}" ] || continue
			[ "${_pt_s_state}" = Z ] && continue
			if grep -zqFx -- "ATHENA_SVC_TREE=${_pt_tag}" "${_pt_d}/environ" 2>/dev/null; then
				echo "${_pt_pid}"; continue
			fi
			[ -n "${_pt_anchors}" ] || continue
			if _pt_under "$(readlink "${_pt_d}/exe" 2>/dev/null)" \
				|| _pt_under "$(readlink "${_pt_d}/cwd" 2>/dev/null)"; then
				echo "${_pt_pid}"
			fi
		done
		echo "scanned ${_pt_n}" >&3
	) 3>"${_pt_scanlog:-/dev/null}"
}

proc_tree_pids() { # TAG UID [ANCHOR...]
	if [ $# -lt 2 ]; then
		_pt_say err "initd-proc-tree: proc_tree_pids needs TAG UID [ANCHOR...]. Fix: pass the service's RC_SVCNAME and its user's uid."
		return 2
	fi
	_pt_t="$1"; _pt_u="$2"; shift 2
	_pt_validate "${_pt_t}" "${_pt_u}" 0 "$@" || return 2
	_pt_scan
}

# _pt_wait_gone SECONDS: re-scan every 0.2s until nothing matches or time is up.
# Sets _pt_left.
_pt_wait_gone() {
	_pt_i=0
	_pt_max=$(( $1 * 5 ))
	_pt_left="$(_pt_scan)"
	while [ -n "${_pt_left}" ] && [ "${_pt_i}" -lt "${_pt_max}" ]; do
		sleep 0.2
		_pt_i=$((_pt_i + 1))
		_pt_left="$(_pt_scan)"
	done
}

_pt_describe() { # pids...
	for _pt_x in "$@"; do
		printf '%s(%s) ' "${_pt_x}" "$(readlink "/proc/${_pt_x}/exe" 2>/dev/null || echo '?')"
	done
}

proc_tree_reap() { # TAG UID TIMEOUT [ANCHOR...]
	if [ $# -lt 3 ]; then
		_pt_say err "initd-proc-tree: proc_tree_reap needs TAG UID TIMEOUT [ANCHOR...]. Fix: pass the service's RC_SVCNAME, its user's uid, and a timeout in seconds."
		return 2
	fi
	_pt_validate "$@" || return 2
	shift 3
	_pt_where="uid ${_pt_uid}, tag ATHENA_SVC_TREE=${_pt_tag}"
	[ -n "${_pt_anchors}" ] && _pt_where="${_pt_where}, under $(printf '%s' "${_pt_anchors}" | tr '\n' ' ')"
	_pt_scanlog="$(mktemp 2>/dev/null || echo /dev/null)"
	_pt_found="$(_pt_scan)"
	_pt_scanned="$(cat "${_pt_scanlog}" 2>/dev/null)"
	if [ -z "${_pt_found}" ]; then
		_pt_say info "${_pt_tag}: no leftover processes (${_pt_scanned:-scanned ?} processes; ${_pt_where})"
		[ "${_pt_scanlog}" = /dev/null ] || rm -f "${_pt_scanlog}"
		_pt_scanlog=""
		return 0
	fi
	# shellcheck disable=SC2086
	_pt_say info "${_pt_tag}: ending leftover processes: $(_pt_describe ${_pt_found})"
	# shellcheck disable=SC2086
	kill -TERM ${_pt_found} 2>/dev/null
	_pt_wait_gone "${_pt_timeout}"
	if [ -n "${_pt_left}" ]; then
		# shellcheck disable=SC2086
		_pt_say info "${_pt_tag}: still running after SIGTERM/${_pt_timeout}s, sending SIGKILL: $(_pt_describe ${_pt_left})"
		# shellcheck disable=SC2086
		kill -KILL ${_pt_left} 2>/dev/null
		_pt_wait_gone 5
	fi
	[ "${_pt_scanlog}" = /dev/null ] || rm -f "${_pt_scanlog}"
	_pt_scanlog=""
	if [ -n "${_pt_left}" ]; then
		# shellcheck disable=SC2086
		_pt_say err "${_pt_tag}: processes survived SIGKILL: $(_pt_describe ${_pt_left})(${_pt_where}). Fix: inspect them with \`ps -o pid,stat,etime,args -p $(echo ${_pt_left} | tr ' ' ',')\`; a D (uninterruptible) state clears when its I/O does. Kill each by PID once it can die, then start the service again. Do not start it while they run: they are a second copy of it."
		return 1
	fi
	_pt_say info "${_pt_tag}: process tree ended (${_pt_scanned}; ${_pt_where})"
	return 0
}
