# proc-env-scan.awk -- which processes carry an environment entry, read so
# that a process caught inside execve is never counted as "does not carry it"
# (DND-1016). One gawk process scans the whole table; nothing is forked.
#
# Usage (gawk only: it needs the filefuncs and time extensions, and RS="\0"):
#
#   gawk -b -f scripts/lib/proc-env-scan.awk \
#     -v mode=tag|exact -v needle=<text> -v uid=<uid> -v since=<ticks> \
#     [-v exclude=<pid,pid>] [-v root=/proc] [-v settle_s=5] /proc/[0-9]*
#
#   mode tag    ATHENA_REAP_TAGS (a comma-separated list) holds <needle> as a
#               whole element
#   mode exact  the environment holds the entry <needle> (VAR=value) exactly
#   uid         only processes whose REAL uid is this are considered
#   since       only processes started at or after this starttime (clock
#               ticks since boot, field 22 of /proc/<pid>/stat): a process
#               started earlier cannot have inherited anything made later
#   exclude     pids never listed (the caller's own shells); this gawk's own
#               pid and its parent are always excluded
#   the operands are /proc/<pid> paths (or bare pids); they are never read as
#   input files, so one that vanished before the scan costs nothing
#
# Output: each matching pid on stdout, one per line. Exit 0 after a clean
# scan; 4 when some pid still could not be told after settle_s seconds (each
# is named on stderr as UNKNOWN, and the matches found are still printed); 2
# on a usage error; 3 when this kernel cannot support the read. A caller must
# treat any non-zero exit as "could not look", never as "none found".
#
# Why the read is bracketed. /proc/<pid>/environ is NOT stable while the
# process is inside execve: from the moment the kernel swaps in the new
# address space until it has laid out the new stack, it reads EMPTY (or fails
# EACCES), and a read that straddles an exec is cut short at a page boundary.
# Measured 2026-09-28: 366 of 3.5M reads of processes going through the asdf
# shim chain missed a tag that was there; a spinner that re-execs itself was
# missing from 58 of 300 plain `grep -z` scans. So a read is an answer only
# when the kernel's own bounds for the environment (env_start and env_end,
# fields 50-51 of /proc/<pid>/stat) are set, are the same before and after the
# read, and span exactly the bytes read. Bounds of 0 0, or two equal bounds
# (the kernel sets env_end = env_start before it walks the new environment),
# mean the process may be mid-exec: "cannot tell yet", which is re-read every
# 0.05s (bounded by settle_s), never counted as "no". Equal bounds that are
# still the same on a re-read are a genuinely empty environment.
#
# A settled read can still be torn (DND-1202). After the exec, the new program
# owns that memory and may rewrite it in place: bash's startup writes a NUL
# over each entry's '=' while it imports the entry, then puts the '=' back.
# A read in between shows the entry split in two ("ATHENA_REAP_TAGS\0<tags>"),
# and was read as "no": 5 of 9929 scans of a bash spinner, and 1 of 200 S12
# scans. The needle's own entry read as a bare name is "cannot tell yet" too.
#
# 0 0 is also what the kernel shows for ANY process the reader may not trace
# (a NON-DUMPABLE one: setuid/file-caps execs such as sudo or fusermount3, or
# a prctl(PR_SET_DUMPABLE, 0) caller such as ssh-agent). Those are told apart
# by who owns /proc/<pid>/environ: the kernel gives a non-dumpable process's
# /proc files to root (the /proc/<pid> directory itself stays the user's),
# and a same-uid exec keeps the process dumpable throughout. Measured: 2000
# of 2000 scans still found the exec-spinner with this check in place.
#
# Limits, stated:
#   * a process that clears or overwrites its own environment (`env -i`) no
#     longer carries the entry;
#   * a NON-DUMPABLE process cannot be read by its own user at all, so it is
#     skipped at once, never listed: a tagged ssh-agent or sudo is not found
#     (the same as before DND-1016, when its read failed EACCES). A harness
#     suite starts none;
#   * the "equal bounds, still equal on a re-read" rule assumes a re-exec
#     lands at a new, randomized stack address. With ASLR off
#     (randomize_va_space=0, or setarch -R) a process re-exec'ing itself
#     between the two reads could read as "empty". It also assumes the
#     kernel's walk of a new environment (microseconds) is not descheduled
#     for the whole 0.05s between the two reads; under PREEMPT a preempted
#     walk could read as "empty". Not observed in 26k scans (DND-1202);
#   * a process that keeps the needle's entry torn (its '=' a NUL) for longer
#     than settle_s is named UNKNOWN (exit 4): loud, never "no".
#
# Shared by scripts/test/lib/suite-reaper.bash (suite_env_pids) and meant for
# any other shell reader of /proc/<pid>/environ (DND-1105:
# system-files/lib/initd-proc-tree.sh). ai/lib/reap_tags.rb applies the same
# rule in Ruby.

@load "filefuncs"
@load "time"

function die(code, msg, fix) {
  printf "proc-env-scan: %s\n  Fix: %s\n", msg, fix > "/dev/stderr"
  exit code
}

# stat_of(pid) -- 1 and ST_STATE, ST_START, ST_E0, ST_E1 set; 0 when gone.
# The WHOLE file is one record (DND-1616): a process name may hold a newline
# as well as ") ", and every pid's stat is read before the scan knows whose
# the process is. Read one line at a time, `x) Z (<newline>y` (proc-state's
# P-6) cut the line inside the name, so ANY such process on the machine, of
# any user, made every scan die with exit 3 and every reap kill nothing. No
# NUL can occur in a stat file, so RS="\0" reads it whole; the fields start
# after its LAST ") " (gawk's "." matches a newline, and ".*" is greedy).
function stat_of(pid,    f, line, n, fld, saved_rs, r) {
  f = root "/" pid "/stat"
  saved_rs = RS; RS = "\0"
  r = (getline line < f)
  close(f); RS = saved_rs
  if (r <= 0) return 0
  sub(/\n$/, "", line)
  if (index(line, ") ") == 0) {
    gsub(/\n/, "\\n", line)        # shown on one line
    die(3, "/proc/" pid "/stat is not in the kernel's format (no \") \" after the comm): " line,
        "run on Linux with /proc mounted; this scan must not guess at a stat line.")
  }
  sub(/^.*\) /, "", line)          # "pid (comm) ": comm may hold spaces, ")" and newlines
  n = split(line, fld, " ")
  if (n < 49) die(3, "/proc/" pid "/stat has " n + 2 " fields; env_start/env_end (fields 50-51, Linux 3.5+) are missing, so a mid-exec read cannot be told from an untagged one.",
                  "run on Linux 3.5 or later; this scan must not fall back to an unbracketed read.")
  ST_STATE = fld[1]; ST_START = fld[20] + 0; ST_E0 = fld[48]; ST_E1 = fld[49]
  return 1
}

# real_uid(pid) -- the real uid from /proc/<pid>/status, or -1 when gone.
function real_uid(pid,    f, line, a, u) {
  f = root "/" pid "/status"; u = -1
  while ((getline line < f) > 0) {
    if (line ~ /^Uid:/) { split(line, a, /[ \t]+/); u = a[2] + 0; break }
  }
  close(f)
  return u
}

# classify(pid) -- 0 matches, 1 does not (or cannot be ours), 2 cannot tell yet.
function classify(pid,    b0, b1, f, e, r, n, hit, torn, got, list, st, saved_rs) {
  if (!stat_of(pid)) return 1
  if (ST_STATE == "Z" || ST_STATE == "X" || ST_STATE == "x") return 1
  if (ST_START < since) return 1
  if (real_uid(pid) != uid) return 1
  # Non-dumpable: root owns its /proc files, its bounds read 0 0 forever and
  # its environ is unreadable. Skipped at once (see Limits), not waited out.
  if (stat(root "/" pid "/environ", st) != 0) return 1  # gone
  if (st["uid"] != uid) return 1
  b0 = ST_E0; b1 = ST_E1
  if (b0 == 0 && b1 == 0) return 2          # mid-exec: no bounds yet
  if (b0 == b1) {
    # Equal bounds are ALSO a mid-exec state: the kernel sets env_end =
    # env_start before it walks the new environment, and only then sets
    # env_end. So equal bounds are an empty environment only when a re-read
    # at least 0.05s later still shows the same ones (an exec's window is
    # microseconds, and a re-exec lands at a new, randomized address).
    if ((pid in seen_empty) && seen_empty[pid] == ST_START ":" b0) return 1
    seen_empty[pid] = ST_START ":" b0
    return 2
  }
  f = root "/" pid "/environ"
  saved_rs = RS; RS = "\0"
  n = 0; hit = 0; torn = 0; got = 0
  while ((r = (getline e < f)) > 0) {
    got = 1
    n += length(e) + length(RT)            # the last entry may lack its NUL
    if (e == var_name) torn = 1             # our entry, its '=' read as NUL
    if (mode == "exact") {
      if (e == needle) hit = 1
    } else if (substr(e, 1, 17) == "ATHENA_REAP_TAGS=") {
      list = "," substr(e, 18) ","
      if (index(list, "," needle ",") > 0) hit = 1
    }
  }
  close(f); RS = saved_rs
  if (!stat_of(pid)) return 1
  if (ST_E0 != b0 || ST_E1 != b1) return 2  # an exec happened during the read
  if (r < 0 && !got) return 2               # unreadable with settled bounds: transient
  if (n != b1 - b0) return 2                # a short read: not the whole environment
  if (hit) return 0
  # DND-1202: the exec is over and the bounds are settled, but the new
  # program may be rewriting its environment in place: bash's startup writes
  # a NUL over each entry's '=' while it imports it, then puts it back. A read
  # in between shows our entry split in two, and without this it read as "no"
  # (1 of 200 S12 scans). Only OUR entry torn counts: a process caught
  # importing another variable can still be told.
  if (torn) return 2
  return 1
}

BEGIN {
  if (length("\303\251") != 2) die(2, "gawk is counting characters, not bytes, so the byte count cannot be checked against the kernel's bounds.", "invoke it as gawk -b -f proc-env-scan.awk ...")
  if (mode != "tag" && mode != "exact") die(2, "mode must be tag or exact, got '" mode "'.", "pass -v mode=tag or -v mode=exact.")
  if (needle == "") die(2, "empty needle; an empty key would match nothing and read as 'none left'.", "pass -v needle=<tag or VAR=value>.")
  if (mode == "exact" && index(needle, "=") < 2) die(2, "mode exact needs a VAR=value needle, got '" needle "'; without a name, a torn read of it cannot be recognized.", "pass -v needle=<VAR>=<value>.")
  # The bare name our entry shows while it is mid-rewrite (its '=' a NUL).
  var_name = (mode == "exact") ? substr(needle, 1, index(needle, "=") - 1) : "ATHENA_REAP_TAGS"
  if (uid !~ /^[0-9]+$/) die(2, "uid must be a number, got '" uid "'.", "pass -v uid=\"$(id -u)\".")
  if (since !~ /^[0-9]+$/) die(2, "since must be a starttime in clock ticks, got '" since "'.", "pass the caller's own starttime (field 22 of /proc/<pid>/stat).")
  if (root == "") root = "/proc"
  if (settle_s == "") settle_s = 5
  if (settle_s !~ /^[0-9]+(\.[0-9]+)?$/) die(2, "settle_s must be a number of seconds, got '" settle_s "'.", "pass -v settle_s=5 (or omit it).")
  uid += 0; since += 0
  split(exclude, ex, ",")
  for (i in ex) skip[ex[i]] = 1
  skip[PROCINFO["pid"]] = 1; skip[PROCINFO["ppid"]] = 1
  if (ARGC < 2) die(2, "no processes to scan; an empty table would read as 'none left'.", "pass the process dirs as operands, e.g. /proc/[0-9]*.")

  nu = 0
  for (i = 1; i < ARGC; i++) {
    pid = ARGV[i]; sub(/^.*\//, "", pid)
    if (pid !~ /^[0-9]+$/ || (pid in skip)) continue
    c = classify(pid)
    if (c == 0) print pid
    else if (c == 2) unknown[++nu] = pid
  }
  rounds = int(settle_s / 0.05)
  for (k = 0; nu > 0 && k < rounds; k++) {
    sleep(0.05)
    m = 0
    for (j = 1; j <= nu; j++) {
      c = classify(unknown[j])
      if (c == 0) print unknown[j]
      else if (c == 2) next_u[++m] = unknown[j]
    }
    delete unknown
    for (j = 1; j <= m; j++) unknown[j] = next_u[j]
    delete next_u
    nu = m
  }
  for (j = 1; j <= nu; j++) {
    f = root "/" unknown[j] "/cmdline"; saved = RS; RS = "\0"; cmd = ""
    while ((getline part < f) > 0) cmd = cmd (cmd == "" ? "" : " ") part
    close(f); RS = saved
    printf "proc-env-scan: pid %s stayed unreadable for %ss (its environment bounds never settled, or its %s entry stayed mid-rewrite), so whether it carries %s is UNKNOWN: %s\n  Fix: find what that process is doing (it is stuck in execve, its environ is unreadable, or it holds its environment half-rewritten) and re-run; this scan could not look, so it exits 4.\n", \
      unknown[j], settle_s, var_name, needle, cmd > "/dev/stderr"
  }
  fflush()
  exit (nu > 0 ? 4 : 0)
}
