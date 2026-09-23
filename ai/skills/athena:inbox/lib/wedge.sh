#!/usr/bin/env bash
# wedge.sh -- the WEDGE SIGNATURE and the capture-dir facts, in ONE place
# (DND-333 / LV-2 wrote them; DND-334 / LV-3 verifies them).
#
# WHY THIS FILE EXISTS. The capture (scripts/inbox-client-capture) computes a
# signature, and the attendant (athena:inbox-attend/bin/wedge-ticket-decide)
# must RECOMPUTE it from the capture on disk before it files or increments a
# ticket: the harness-alerts message is untrusted input, the capture is the
# authority. Two copies of the signature algorithm would drift, and a drifted
# verifier refuses every genuine alert while reading as "tampered". So both
# sides source this file and there is exactly one algorithm on the machine.
#
# THE SIGNATURE: sha256 over "step:<step>\n<frames>\n", where <frames> is the
# top 5 frames of the thread blocked in that step, each reduced to
# `file:function` (no directories, line numbers or addresses), so the same
# wedge after a code shuffle keeps its signature. The thread is the step's
# worker (a frame `block in ...with_deadline`) when there is one, else the
# first thread listed (MRI lists the main thread first). No dump -> no frames.
#
# BUCKETS. wedge_signature and wedge_valid_* are pure (Domain). wedge_frames
# and wedge_cycle_counts read one file each (Side Effects, read-only).

# The capture directory name: <UTCbasic>Z-<pid>[-<n>]. Mirrors
# inbox-client-capture's retention regex; a name outside it is not a capture.
WEDGE_CAPTURE_NAME_RE='^[0-9]{8}T[0-9]{6}Z-[0-9]+(-[0-9]+)?$'

# wedge_frames <dump-file> -- the top-5 `file:function` frames, one per line.
# Prints nothing for a dump with no threads section.
wedge_frames() {
  awk '
    /^threads \(/ { inth = 1; next }
    inth && /^  thread / { t++; next }
    inth && /^    / {
      f = $0; sub(/^ +/, "", f)
      if (f ~ /^\(no backtrace/) next
      n[t]++; fr[t, n[t]] = f
      if (f ~ /block in .*with_deadline/) w[t] = 1
      next
    }
    inth && /^[^ ]/ { inth = 0 }
    END {
      pick = 0
      for (i = 1; i <= t; i++) if (w[i]) { pick = i; break }
      if (!pick && t >= 1) pick = 1
      for (j = 1; j <= n[pick] && j <= 5; j++) {
        f = fr[pick, j]
        fn = f; sub(/^.*:in [`'"'"']/, "", fn); sub(/'"'"'$/, "", fn)
        file = f; sub(/:[0-9]+:in .*$/, "", file); sub(/^.*\//, "", file)
        print file ":" fn
      }
    }' "$1"
}

# wedge_signature <step> <frames> -- the 64-hex signature.
wedge_signature() {
  printf 'step:%s\n%s\n' "$1" "$2" | sha256sum | cut -d' ' -f1
}

# wedge_valid_signature <s> -- status 0 for exactly 64 lowercase hex chars.
wedge_valid_signature() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

# wedge_valid_step <s> -- a step name as the liveness judge produces them
# (dns, tcp_connect, tls, ws_upgrade, join, sleep, reconnect, start, after_x,
# unknown). It goes into a ticket TITLE, so anything else is refused.
wedge_valid_step() {
  [[ "$1" =~ ^[a-z][a-z0-9_]{0,31}$ ]]
}

# --- retention (DND-367) -----------------------------------------------------
#
# Retention used to keep the newest KEEP captures, full stop. A capture whose
# harness-alerts message was still UNREAD could be pruned first; the attendant
# then could not recompute its signature, refused the alert, and the occurrence
# was lost: the silent-loss class. So a capture an unread alert references is
# never pruned to meet KEEP. Only the HARD MAX may prune it, and that prune is
# recorded under its own reason in the prune ledger, so the attendant reports it
# as "pruned before processing", never as tampering.
#
# When the references could NOT be read (the channel does not resolve, jq is
# missing, the registry is unreadable), every capture is treated as referenced.
# A failed lookup must not read as "none referenced": that is the exact silent
# prune this exists to stop. The hard max still bounds the disk.

# The prune ledger's basename, in the dump directory. One line per pruned
# capture: "<UTC>\t<capture name>\t<reason>". Written by inbox-client-capture,
# read by athena:inbox-attend/bin/wedge-ticket-decide.
WEDGE_PRUNE_LEDGER="pruned-captures.log"

# wedge_retention_plan <keep> <hard_max> <refs_known 0|1>
# stdin: "<capture name>\t<referenced 0|1>" lines, OLDEST FIRST, for the
# captures that exist BEFORE the new one is written. stdout: the ones to prune,
# as "<name>\t<reason>", oldest first. PURE.
#   pass 1  unreferenced captures, oldest first, until KEEP-1 remain -> retention
#   pass 2  anything, oldest first, until HARD_MAX-1 remain ->
#           hard-max-while-unread (references known) or
#           hard-max-references-unknown (they could not be read)
# The "-1" leaves room for the capture about to be written, which is never a
# candidate because it does not exist yet.
wedge_retention_plan() {
  awk -F'\t' -v keep="$1" -v hard="$2" -v known="$3" '
    $1 != "" { n++; name[n] = $1; ref[n] = (known == 1) ? ($2 == 1) : 1 }
    END {
      left = n
      for (i = 1; i <= n && left > keep - 1; i++)
        if (!ref[i]) { gone[i] = "retention"; left-- }
      why = (known == 1) ? "hard-max-while-unread" : "hard-max-references-unknown"
      for (i = 1; i <= n && left > hard - 1; i++)
        if (!(i in gone)) { gone[i] = why; left-- }
      for (i = 1; i <= n; i++) if (i in gone) print name[i] "\t" gone[i]
    }'
}

# wedge_pruned_record <dump-dir> <capture name>
# Prints "<UTC>\t<reason>" from the LAST ledger line naming <name> exactly, or
# returns 1 when the ledger has none (or does not exist). Read-only.
wedge_pruned_record() {
  local ledger="$1/${WEDGE_PRUNE_LEDGER}"
  [ -f "${ledger}" ] && [ ! -L "${ledger}" ] || return 1
  awk -F'\t' -v n="$2" '$2 == n { r = $1 "\t" $3; f = 1 } END { if (f) print r; exit !f }' "${ledger}"
}

# wedge_cycle_counts <client-log>
# Prints "<reconnecting>\t<connected>\t<since>": how many `reconnecting in` and
# (log level INFO, WARN or ERROR, as liveness.sh admits them)
# `connected to` lines the client logged since the supervisor last (re)started
# it (the last `SUPERVISOR supervising` / `SUPERVISOR client exited` line), or
# since the start of the live log when neither is in it (since = "log start").
# A missing log prints "n/a\tn/a\tno log" -- never 0, which would be a
# measurement (a 0 is "it never reconnected", an absent log is "we cannot say").
wedge_cycle_counts() {
  local log="$1"
  if [ ! -r "${log}" ]; then printf 'n/a\tn/a\tno log\n'; return 0; fi
  awk '
    / SUPERVISOR (supervising |client exited )/ { r = 0; c = 0; since = "last restart"; next }
    / (INFO|WARN|ERROR) reconnecting in / { r++ }
    / (INFO|WARN|ERROR) connected to /    { c++ }
    END { if (since == "") since = "log start"; printf "%d\t%d\t%s\n", r, c, since }' "${log}"
}
