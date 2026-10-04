# shellcheck shell=bash
#
# outbound-text-scan.sh — the forge-neutral half of the outbound scan that
# gh-athena (ai/lib/gh-outbound-scan.sh, DND-699) and glab-athena
# (ai/lib/glab-outbound-scan.sh, DND-1938) run on text bound for a PUBLIC
# repository or project. Sourced, never run.
#
# One set of rules for both forges. Each forge guard names its CLI's text,
# file and target flags and decides whether the target is public; the rest
# lives here: how an argv is read (ots_pflag_parse, with the CLI's pinned flag
# table), an api call's fields (ots_api_collect), how a field reaches the
# scanner (a private copy, never argv), and what each scanner outcome means.
#
#   CLEAN / WAIVED - NOT SCANNED   the write goes ahead (the scanner's line is
#                                  shown on stderr)
#   HITS                           REFUSED, exit 1: labels and locations only
#   COULD NOT MEASURE              REFUSED, exit 3, except where the overlay is
#                                  ABSENT and this machine is not marked as one
#                                  that holds it (no outbound pre-push hook in
#                                  the harness checkout's common git dir). There
#                                  the write goes ahead, and a WARNING says the
#                                  text went out UNSCANNED. The overlay is
#                                  optional (contract -> Discovery); the
#                                  installed hook is the mark of a machine that
#                                  must measure.
#   exit 1 without HITS, other     REFUSED, exit 3: a scanner failure is never
#                                  read as a result
#
# How an argv is read (DND-1976). gh and glab both parse flags with pflag, and
# pflag gives a flag that takes a value the NEXT word, even one that starts
# with `-`: `-l -t -b X` is label `-t`, body X. A parse that does not know -l
# takes a value reads `-t` as the title, and X goes out unscanned. Two rules,
# shared by both guards, close that class:
#
#   1. A word the parse cannot place is scanned or refused, never dropped.
#      Each guard parses with a pinned table of every flag of every command it
#      judges and whether it takes a value (ai/lib/gh-flag-table.sh,
#      ai/lib/glab-flag-table.sh, built by ai/bin/cli-flag-table from the
#      CLI's own help). gh-athena REFUSES a flag its table lacks. glab-athena
#      runs on glab versions whose flags differ, so a flag its table lacks is
#      read as taking nothing unless the next word could be read as a flag or
#      is `--`; then it is REFUSED (lenient mode). A guard's own text, file
#      and target flags always take a value, in the table or not. Every
#      positional is scanned when the command carries text.
#   2. A flag value given as its own word that, read as a flag, names one of
#      the command's FILE or TARGET flags (`--label -F <file>`, `-l -R <repo>`)
#      is REFUSED: should the table have drifted, that file is sent unscanned,
#      or that repository decides the visibility. A value naming a TEXT flag
#      (`--label -b X`) makes every positional text. Text values are exempt
#      (they are scanned either way). The attached form (`--label=-F`) is never
#      ambiguous.
#
# The caller sets:
#   OTS_TOOL   the wrapper's name, the prefix of every line (gh-athena)
#   OTS_WHAT   the command being judged, for messages ("pr create")
#   OTS_DEST   what a public target is called ("repository", "project")
#   FCI_CFG_DIR  the wrapper's private config dir (ai/lib/forge-cli-isolation.sh);
#              the private copies go in its outbound-scan/ subdirectory.
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh and
# ai/test/glab-athena-outbound/self-test.sh drive the real wrappers.

OTS_BIN_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin"
OTS_TOOL="${OTS_TOOL:-outbound-scan}"
OTS_WHAT="${OTS_WHAT:-write}"
OTS_DEST="${OTS_DEST:-repository}"
OTS_COPY=""

# ots_refuse <exit code> <message with its Fix:> : prints and exits.
ots_refuse() {
  local rc="$1"; shift
  printf '%s: REFUSED: %s\n' "$OTS_TOOL" "$*" >&2
  exit "$rc"
}

# ots_machine_marked : 0 when the harness checkout holding this library has the
# outbound pre-push hook installed in its common git dir.
#
# Three outcomes, never two: 0 marked, 1 not marked (the hook path resolved
# and holds no outbound hook), 2 could not determine (git could not resolve
# the hook path, or the hook exists but cannot be read). The caller treats 2
# as "must measure": a failed lookup never reads as "not marked". The hook
# path honours core.hooksPath (git rev-parse --git-path).
ots_machine_marked() {
  local hook
  hook="$(git -C "$OTS_BIN_DIR" rev-parse --path-format=absolute --git-path hooks/pre-push 2>/dev/null)" || return 2
  [ -n "$hook" ] || return 2
  [ -e "$hook" ] || return 1
  [ -r "$hook" ] || return 2
  if grep -q -e outbound-scan -e outbound-pre-push "$hook" 2>/dev/null; then return 0; fi
  return 1
}

# ots_scan <label> <file> : run the scanner on one field; handles the outcome.
ots_scan() {
  local label="$1" file="$2" out rc=0
  out="$("$OTS_BIN_DIR/outbound-scan" --text "$file" --label "$label" 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed "s/^/$OTS_TOOL: /" >&2
  case "$rc" in
    0) return 0 ;;
    1)
      # Exit 1 is HITS only when the scanner says so; a crash (a Ruby
      # exception is also exit 1) is a scanner failure, never read as a result.
      case "$out" in
        *"outbound-scan: HITS mode="*) ;;
        *) ots_refuse 3 "the outbound scanner exited 1 on the $label without reporting HITS (a crash, output above). Fix: run \`$OTS_BIN_DIR/outbound-scan --help\` and report the defect." ;;
      esac
      ots_refuse 1 "the $label of this $OTS_WHAT to a PUBLIC $OTS_DEST carries work-domain values (locations and labels above). Fix: remove them from the $label, or read them from the private overlay instead of pasting them (ai/contracts/athena-private-overlay.md -> Consumer obligation), then retry." ;;
    3)
      local st=0
      "$OTS_BIN_DIR/private-overlay" status >/dev/null 2>&1 || st=$?
      local marked=0
      ots_machine_marked || marked=$?
      if [ "$st" = 3 ] && [ "$marked" = 1 ]; then
        printf '%s: WARNING: the %s of this %s went out UNSCANNED: the private overlay is ABSENT and this machine is not marked as one that holds it (no outbound pre-push hook installed). This is not a clean result. Fix: none needed on a machine without the overlay; on one that should hold it, the owner creates it with scripts/setup-private-overlay --init and installs the hook with scripts/setup-private-overlay --install.\n' "$OTS_TOOL" "$label" "$OTS_WHAT" >&2
        return 0
      fi
      ots_refuse 3 "the outbound scan of the $label could not measure (above), and this machine must measure. Fix: the Fix: line above names the problem; correct it and retry." ;;
    *) ots_refuse 3 "the outbound scanner failed (exit $rc) on the $label. Fix: run \`$OTS_BIN_DIR/outbound-scan --help\` and correct the call; report the defect if the call was right." ;;
  esac
}

# ots_dir : echoes the private directory the copies go in, creating it.
ots_dir() {
  [ -n "${FCI_CFG_DIR:-}" ] || ots_refuse 3 "the private config dir (FCI_CFG_DIR) is unset, so the outbound scan has nowhere to copy the text. Fix: run $OTS_TOOL as a whole (it sets the dir up before this guard); report a defect if it did."
  local dir="$FCI_CFG_DIR/outbound-scan"
  mkdir -p "$dir" || ots_refuse 3 "could not create $dir for the outbound scan. Fix: make \$TMPDIR writable and retry."
  printf '%s\n' "$dir"
}

# ots_scan_text <label> <noun> <key> <text> : writes <text> to a private file
# named <key> and scans it. <noun> names the field in a refusal ("body").
ots_scan_text() {
  local label="$1" noun="$2" key="$3" text="$4" dir f
  dir="$(ots_dir)" || exit 3
  f="$dir/$key"
  printf '%s\n' "$text" > "$f" || ots_refuse 3 "could not write the $noun to $f for the outbound scan. Fix: make \$TMPDIR writable and retry."
  ots_scan "$label" "$f"
}

# ots_copy_scan <label> <noun> <flag> <key> <path or -> : copies the file (or
# stdin, for `-`) once into a private file named <key>, sets OTS_COPY to it,
# and scans the copy. The caller hands the CLI OTS_COPY in place of the
# original: a pipe (-F <(...), /dev/fd/N, a FIFO, stdin) can be read only
# once, and a regular file can change between the scan and the CLI's own read.
# <flag> is the option the caller should pass instead, for a Fix:.
ots_copy_scan() {
  ots_copy "$2" "$3" "$4" "$5"
  ots_scan "$1" "$OTS_COPY"
}

# ots_copy <noun> <flag> <key> <path or -> : the copy half of ots_copy_scan,
# for a caller that must read the text before it decides to scan (a GraphQL
# query, read once from the copy rather than twice from a pipe). <key> may
# hold one `/`, for a copy that must keep its source's file name (a multipart
# upload names the part after the path it is handed): `<dir>/<basename>`.
ots_copy() {
  local noun="$1" flag="$2" key="$3" src="$4" dir f
  dir="$(ots_dir)" || exit 3
  f="$dir/$key"
  if [[ "$key" == */* ]]; then
    mkdir -p "${f%/*}" || ots_refuse 3 "could not create ${f%/*} for the outbound scan. Fix: make \$TMPDIR writable and retry."
  fi
  if [ "$src" = "-" ]; then
    cat > "$f" || ots_refuse 3 "could not read the $noun from stdin. Fix: pass $flag <path> instead."
  else
    [ -r "$src" ] || ots_refuse 3 "the $noun file $src is not readable, so it cannot be scanned. Fix: pass a readable $flag."
    cat -- "$src" > "$f" || ots_refuse 3 "could not copy the $noun file $src for the outbound scan. Fix: pass a readable regular file and retry."
  fi
  OTS_COPY="$f"
  return 0
}

# ---- reading an argv (DND-1976) --------------------------------------------

# ots_flag_shaped <word> : true when pflag would read <word> as a flag (`-x…`,
# `--x…`). A lone `-` (stdin) and `--` are not.
ots_flag_shaped() { [[ "$1" =~ ^--?[A-Za-z0-9] ]]; }

# ots_names_flag <word> <short letters> <" --long --long "> : true when <word>,
# read as a flag, names one of the given flags: `--long` or `--long=…`, or a
# single-dash cluster with one of the letters anywhere before an `=` (pflag
# may read any letter of a cluster as a flag).
ots_names_flag() {
  local w="$1" letters="$2" longs="$3" c
  ots_flag_shaped "$w" || return 1
  if [[ "$w" == --* ]]; then
    [[ "$longs" == *" ${w%%=*} "* ]]; return
  fi
  c="${w#-}"; c="${c%%=*}"
  [ -n "$letters" ] && [[ "$c" == *["$letters"]* ]]
}

# ots_refuse_flag_value <flag> <value> : rule 2 of the header.
ots_refuse_flag_value() {
  ots_refuse 3 "the value of $1 in this $OTS_WHAT is \`$2\`, which looks like a flag that names a file or a repository. pflag may read it either way, and under one reading that file is sent, or that repository targeted, without the outbound scan. Fix: attach the value to its flag (\`$1=$2\`) if you meant it, or give $1 a real value."
}

# ots_pflag_parse <table> <offset> <args...> : reads <args> the way pflag
# reads them, with <table> the command's flags (" <v|b>:<short>:<long> … ",
# the <P>_FLAGS format of ai/lib/<cli>-flag-table.sh). Returns 1 on a word it
# cannot place (an unknown flag, `--=x`, `---x`), naming it in OTS_UNKNOWN.
# With OTS_LENIENT set, an unknown flag is read as taking nothing, and the
# return is 2 (OTS_UNKNOWN, and OTS_AMBIG the word that makes it ambiguous)
# only when that reading could be wrong in a way that matters: the next word
# could be read as a flag or is `--`, or the flag is a letter with more of its
# word after it. Otherwise returns 0 and sets, per value-taking flag
# occurrence, in order:
#   OTS_FN   its long name (no dashes)
#   OTS_FV   its value
#   OTS_FI   <offset> + the index of the word that holds the value
#   OTS_FP   the text before the value in that word ("" when the value is
#            its own word; `--body-file=`, `-F`, `-dF`, `-F=` when attached)
#   OTS_FS   1 when the value is its own word, else 0
# and OTS_PO / OTS_POI, every positional and its index (everything after `--`
# included). OTS_HELP is 1 when the argv asks for help with an undefined -h,
# which pflag answers without running the command. The pflag rules: `--name=v`; `--name v` (v taken even when it
# starts with `-`); `-abc` letter by letter, where a value-taking letter takes
# the rest of the word (`-tX`, `-t=X`), or the next word when it is last; a
# switch letter followed by `=` takes the rest as its value (`-d=true`); a
# lone `-` is positional.
ots_pflag_parse() {
  local table="$1" off="$2"; shift 2
  local -a args=("$@")
  local n=$# i=0 a name long j sh c rest
  OTS_FN=() OTS_FV=() OTS_FI=() OTS_FP=() OTS_FS=() OTS_PO=() OTS_POI=() OTS_UNKNOWN="" OTS_HELP="" OTS_AMBIG=""
  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    if [ "$a" = "--" ]; then
      for ((j = i + 1; j < n; j++)); do OTS_PO+=("${args[$j]}"); OTS_POI+=($((off + j))); done
      break
    fi
    case "$a" in
      --*)
        name="${a#--}"
        if [ -z "$name" ] || [[ "$name" == [-=]* ]]; then OTS_UNKNOWN="$a"; return 1; fi
        long="${name%%=*}"
        if ! ots_table_long "$table" "$long"; then
          OTS_UNKNOWN="--$long"
          [ -n "${OTS_LENIENT:-}" ] || return 1
          if [[ "$name" != *=* ]] && ots_pflag_ambiguous "${args[@]:$((i + 1)):1}"; then return 2; fi
          i=$((i + 1)); continue
        fi
        if [[ "$name" == *=* ]]; then
          if [ "$OTS_K" = v ]; then ots_pflag_rec "$long" "${name#*=}" $((off + i)) "--$long=" 0; fi
        elif [ "$OTS_K" = v ]; then
          i=$((i + 1)); ots_pflag_rec "$long" "${args[$i]-}" $((off + i)) "" 1
        fi ;;
      -?*)
        sh="${a#-}"; j=0
        while [ "$j" -lt "${#sh}" ]; do
          c="${sh:$j:1}"; rest="${sh:$((j + 1))}"
          if ! ots_table_short "$table" "$c"; then
            # pflag answers an undefined -h with the help and stops: the
            # command never runs, so nothing is sent.
            if [ "$c" = h ]; then OTS_HELP=1; return 0; fi
            OTS_UNKNOWN="-$c (in '$a')"
            [ -n "${OTS_LENIENT:-}" ] || return 1
            # Lenient: the letter may take the rest of the word, or the next
            # word, as its value; either way it is ambiguous when what follows
            # could be read as flags.
            if [ -n "$rest" ]; then OTS_AMBIG="$rest"; return 2; fi
            if ots_pflag_ambiguous "${args[@]:$((i + 1)):1}"; then return 2; fi
            break
          fi
          if [ "${#rest}" -ge 2 ] && [ "${rest:0:1}" = "=" ]; then
            if [ "$OTS_K" = v ]; then ots_pflag_rec "$OTS_L" "${rest:1}" $((off + i)) "-${sh:0:$((j + 1))}=" 0; fi
            break
          elif [ "$OTS_K" = b ]; then
            j=$((j + 1)); continue
          elif [ -n "$rest" ]; then
            ots_pflag_rec "$OTS_L" "$rest" $((off + i)) "-${sh:0:$((j + 1))}" 0; break
          else
            i=$((i + 1)); ots_pflag_rec "$OTS_L" "${args[$i]-}" $((off + i)) "" 1; break
          fi
        done ;;
      *) OTS_PO+=("$a"); OTS_POI+=($((off + i))) ;;
    esac
    i=$((i + 1))
  done
  return 0
}

ots_pflag_rec() { OTS_FN+=("$1"); OTS_FV+=("$2"); OTS_FI+=("$3"); OTS_FP+=("$4"); OTS_FS+=("$5"); }

# ots_flag_letters <table> <" long long "> : sets OTS_LETTERS to the short
# letters of the named flags and OTS_LONGS to their " --long " spellings.
ots_flag_letters() {
  local e rest s l
  OTS_LETTERS="" OTS_LONGS=" "
  for e in $1; do
    rest="${e#*:}"; s="${rest%%:*}"; l="${rest#*:}"
    if [[ "$2" == *" $l "* ]]; then
      OTS_LONGS+="--$l "
      OTS_LETTERS+="$s"
    fi
  done
}

# ots_with_roles <table> <" role longs "> : echoes <table> with every named
# flag it lacks added as taking a value. A guard's text, file and target flags
# always take one, whatever the CLI version the table was built from.
ots_with_roles() {
  local t="$1" l
  for l in $2; do ots_table_long "$t" "$l" || t+=" v::$l "; done
  printf '%s' "$t"
}

# ots_collect <table> <" text longs "> <" file longs "> <" target longs "> :
# after ots_pflag_parse, sorts every value it read into the caller's texts/
# tlab, fsrc/fidx/fpre/flab/fnoun/fflag and targets (dynamic scope), and
# applies rule 2 of the header: a value given as its own word that names a
# file or target flag is REFUSED, and one that names a text flag sets
# OTS_POS_TEXT (every positional is then text). Sets OTS_HAVE_TARGET when a
# target flag was given.
ots_collect() {
  local table="$1" tx="$2" fl="$3" tg="$4" k role name val
  local ft_letters ft_longs tx_letters tx_longs
  OTS_POS_TEXT="" OTS_HAVE_TARGET=""
  ots_flag_letters "$table" "$fl $tg "; ft_letters="$OTS_LETTERS" ft_longs="$OTS_LONGS"
  ots_flag_letters "$table" "$tx"; tx_letters="$OTS_LETTERS" tx_longs="$OTS_LONGS"
  for k in "${!OTS_FN[@]}"; do
    name="${OTS_FN[$k]}" val="${OTS_FV[$k]}" role=""
    if [[ "$tx" == *" $name "* ]]; then role=text
    elif [[ "$fl" == *" $name "* ]]; then role=file
    elif [[ "$tg" == *" $name "* ]]; then role=target; fi
    if [ "$role" != text ] && [ "${OTS_FS[$k]}" = 1 ]; then
      if ots_names_flag "$val" "$ft_letters" "$ft_longs"; then ots_refuse_flag_value "--$name" "$val"; fi
      if ots_names_flag "$val" "$tx_letters" "$tx_longs"; then OTS_POS_TEXT=1; fi
    fi
    case "$role" in
      text) texts+=("$val"); tlab+=("$name") ;;
      file)
        fsrc+=("$val"); fidx+=("${OTS_FI[$k]}"); fpre+=("${OTS_FP[$k]}")
        flab+=("$name"); fnoun+=("${name%-file}"); fflag+=("--$name") ;;
      target) targets+=("$val"); OTS_HAVE_TARGET=1 ;;
    esac
  done
}

# ots_pflag_ambiguous [<next word>] : lenient mode, after a flag the table does
# not have. True (with OTS_AMBIG set) when the next word exists and pflag would
# read it as a flag or as `--` were the unknown flag a switch: then whether
# that word is the unknown flag's value or a flag of its own decides what is
# sent, and the parse cannot tell.
ots_pflag_ambiguous() {
  [ $# -gt 0 ] || return 1
  if [ "$1" = "--" ] || ots_flag_shaped "$1"; then OTS_AMBIG="$1"; return 0; fi
  return 1
}

# ots_table_long <table> <long> / ots_table_short <table> <letter> : 0 when
# the table has the flag, with OTS_K its kind (v|b) and OTS_L its long name.
# Matched word by word, never as a pattern: the name comes from argv.
ots_table_long() {
  local e
  for e in $1; do
    if [ "${e#*:*:}" = "$2" ]; then OTS_K="${e%%:*}"; OTS_L="$2"; return 0; fi
  done
  return 1
}
ots_table_short() {
  local e rest
  for e in $1; do
    rest="${e#*:}"
    if [ "${rest%%:*}" = "$2" ]; then OTS_K="${e%%:*}"; OTS_L="${rest#*:}"; return 0; fi
  done
  return 1
}

# ---- api writes (DND-1938; forge-neutral since DND-1976) --------------------
# glab-athena's api scan uses these. gh-athena does not scan `gh api`: its
# scan runs before the merge guard, and an api scan must run after it, as
# glab-athena's does (the order is ai/bin/gh-athena's).

# ots_upload_name <path or -> : the file name a multipart upload of <path>
# carries, for its scanned copy. Stdin and a name with no usable last segment
# get a fixed name.
ots_upload_name() {
  local b="${1##*/}"
  case "$1:$b" in
    -:* | *: | *:. | *:..) b=upload ;;
  esac
  printf '%s' "$b"
}

# ots_api_collect <argv array name> <offset of the first word after `api`>
# <leading segment to drop…> : after fas_parse_api (ai/lib/forge-api-scan.sh,
# which the caller sources) has parsed an `api` call. Returns 1 when the call
# is not a write. A write is any method but GET/HEAD (the CLIs default to
# POST when fields or --input are given), or one a method-override header or
# a `_method` field could turn into a write. For a write, appends every field
# (inline text to the caller's texts/tlab; an @file, @- or --input to its
# fsrc/fidx/fpre/flab/fnoun/fflag/fbase) and the endpoint itself when it has a
# ?query or #fragment, and sets OTS_API_GRAPHQL to 1 when an endpoint is the
# bare `graphql`. A GraphQL call is judged by reading its query, and a pipe or
# stdin can be read once: so every file of one is copied first, the copy
# replaces it in the argv, and both the mutation check and the CLI read it.
ots_api_collect() {
  local -n _argv="$1"
  local off="$2" method write k ep
  shift 2
  OTS_API_GRAPHQL=""
  method="$FAS_METHOD"
  if [ -z "$method" ]; then
    if [ "$FAS_NPARAMS" -gt 0 ] || [ -n "$FAS_INPUT" ]; then method=POST; else method=GET; fi
  fi
  write=1
  case "$method" in GET | HEAD) write=0 ;; esac
  if [ "$FAS_OVERRIDE" = 1 ]; then write=1; fi
  for k in "${FAS_FKEY[@]}"; do if [ "$k" = _method ]; then write=1; fi; done
  [ "$write" = 1 ] || return 1

  for k in "${!FAS_FKIND[@]}"; do
    case "${FAS_FKIND[$k]}" in
      file | formfile)
        fsrc+=("${FAS_FVAL[$k]#@}"); fidx+=($((off + FAS_FIDX[k])))
        fpre+=("${FAS_FPRE[$k]}${FAS_FKEY[$k]}=@"); flab+=(field-file); fnoun+=(field); fflag+=("-F ${FAS_FKEY[$k]}=@<path>")
        # A --form file is a multipart upload, named after the path the CLI is
        # handed: the copy keeps the source's file name.
        if [ "${FAS_FKIND[$k]}" = formfile ]; then fbase[$((${#fsrc[@]} - 1))]="$(ots_upload_name "${FAS_FVAL[$k]#@}")"; fi ;;
      *)
        texts+=("${FAS_FKEY[$k]}=${FAS_FVAL[$k]}"); tlab+=(field) ;;
    esac
  done
  if [ -n "$FAS_INPUT" ]; then
    fsrc+=("$FAS_INPUT"); fidx+=($((off + FAS_INPUT_IDX))); fpre+=("$FAS_INPUT_PRE")
    flab+=(input); fnoun+=(body); fflag+=(--input)
  fi
  for ep in "${FAS_POS[@]}"; do
    if [[ "$ep" == *[?#]* ]]; then texts+=("$ep"); tlab+=(endpoint); fi
    if ep="$(fas_path "$ep" "$@")" && [ "${ep,,}" = graphql ]; then OTS_API_GRAPHQL=1; fi
  done

  if [ -n "$OTS_API_GRAPHQL" ] && [ "${#fsrc[@]}" -gt 0 ]; then
    FAS_FILES=()
    for k in "${!fsrc[@]}"; do
      ots_copy "${fnoun[$k]}" "${fflag[$k]}" "graphql-$k${fbase[$k]:+/${fbase[$k]}}" "${fsrc[$k]}"
      fsrc[k]="$OTS_COPY"
      _argv[${fidx[$k]}]="${fpre[$k]}$OTS_COPY"
      if [ "${flab[$k]}" = input ]; then FAS_INPUT="$OTS_COPY"; else FAS_FILES+=("$OTS_COPY"); fi
    done
  fi
  return 0
}

# ots_scan_all <argv array name> : scans every collected field: the caller's
# texts/tlab, and fsrc/fidx/fpre/flab/fnoun/fflag/fbase, each file copied once
# and replaced in the argv by its scanned copy. Exits 1 (HITS) or 3; returns 0.
ots_scan_all() {
  local -n _sargv="$1"
  local k
  for k in "${!texts[@]}"; do ots_scan_text "${tlab[$k]}" "${tlab[$k]}" "text-$k" "${texts[$k]}"; done
  for k in "${!fsrc[@]}"; do
    ots_copy_scan "${flab[$k]}" "${fnoun[$k]}" "${fflag[$k]}" "file-$k${fbase[$k]:+/${fbase[$k]}}" "${fsrc[$k]}"
    _sargv[${fidx[$k]}]="${fpre[$k]}$OTS_COPY"
  done
  return 0
}
