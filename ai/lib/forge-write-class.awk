# forge-write-class.awk — which plain `gh` / `glab` command is a forge WRITE
# (DND-1179, shared since DND-1803). Function definitions only: no BEGIN, no
# pattern, no main rule. A caller loads this text in front of its own program.
#
# Two callers, one classification:
#   * ai/hooks/forge-identity-guard.sh, the lexical PreToolUse hook. It splits
#     the Bash command text into words and calls judge() on every gh/glab word.
#   * ai/lib/agent-forge-cli.sh, behind the agent PATH wrappers ai/agent-bin/gh
#     and ai/agent-bin/glab. It has the real argv and calls judge(1).
#
# The model is POSITIVE (DND-1179): for each known command group a READ
# allowlist (RD); any other verb of that group is a write. A group with no
# forge write is allowed whole (AG). A word that is no known group is allowed:
# it is prose (to the hook), an alias or an extension (the named residual).
# `api` is judged by its method (api_write).
#
# The caller sets, before judge():
#   t[1..n], n   the words; t[i] is the gh/glab command word judge(i) reads
#   MUT          1 when the command's text holds the word `mutation`
# and calls fwc_init() once first. judge(i) prints one line
#   <cli> TAB <group> TAB <verb> TAB <the group's reads>
# and EXITS on a write; it returns, printing nothing, on a read. For `api` the
# group field is `api` and the verb and reads fields are empty.
#
# Known gaps (each a false deny of a read, one retry through the wrapper):
# `gh issue develop --list`, `gh codespace ssh|code|cp`, a read flag placed
# between the group and the verb that takes a value valued() does not know,
# and --help / -h right after a bare flag (`--web --help`), which may be that
# flag's value (DND-1843).
# The hook's self-test (K1, K2) reads the installed CLIs and fails on any group
# that is in neither AG nor RD, so a CLI upgrade turns it red instead of
# failing open. glab does not list its group aliases; those (var, project,
# pipe, pipeline, stacks, sched, skd) are kept by hand.

function fwc_init(    c, na, a, x) {
  # Groups (and group aliases) with no forge write: allowed whole.
  AGS["gh"] = "auth config completion help version extension extensions ext search status browse attestation at ruleset rs preview org accessibility a11y licenses"
  AGS["glab"] = "auth config completion help version check-update changelog user iteration work-items attestation whatsnew"
  for (c in AGS) { na = split(AGS[c], a, " "); for (x = 1; x <= na; x++) AG[c " " a[x]] = 1 }
  # READ allowlists: "|verb|" or "|verb subverb|", verb aliases included.
  # Every other verb of the group writes.
  RD["gh pr"] = "|list|ls|view|status|checks|diff|checkout|co|"
  RD["gh issue"] = "|list|ls|view|status|"
  RD["gh repo"] = "|list|ls|view|clone|set-default|read-dir|read-file|deploy-key list|deploy-key ls|autolink list|autolink ls|autolink view|gitignore list|gitignore view|license list|license view|"
  RD["gh release"] = "|list|ls|view|download|verify|verify-asset|"
  RD["gh run"] = "|list|ls|view|watch|download|"
  RD["gh workflow"] = "|list|ls|view|"
  RD["gh label"] = "|list|ls|"
  RD["gh secret"] = "|list|ls|"
  RD["gh variable"] = "|list|ls|get|"
  RD["gh gist"] = "|list|ls|view|clone|"
  RD["gh cache"] = "|list|ls|"
  RD["gh project"] = "|list|ls|view|field-list|item-list|"
  RD["gh codespace"] = "|list|ls|view|logs|ports|"
  RD["gh cs"] = RD["gh codespace"]
  RD["gh ssh-key"] = "|list|ls|"
  RD["gh gpg-key"] = "|list|ls|"
  RD["gh agent-task"] = "|list|ls|view|"
  RD["gh agent-tasks"] = RD["gh agent-task"]; RD["gh agent"] = RD["gh agent-task"]; RD["gh agents"] = RD["gh agent-task"]
  RD["gh discussion"] = "|list|ls|view|"
  RD["gh skill"] = "|list|ls|preview|search|install|update|"
  RD["gh skills"] = RD["gh skill"]
  RD["gh alias"] = "|list|ls|delete|"
  # Runs an agent that can write as the owner: no verb is a read.
  RD["gh copilot"] = "|"
  RD["glab mr"] = "|list|ls|view|show|diff|checkout|issues|approvers|note list|"
  RD["glab issue"] = "|list|ls|view|show|board view|"
  RD["glab ci"] = "|list|ls|view|status|trace|get|lint|config|artifact|"
  RD["glab pipeline"] = RD["glab ci"]; RD["glab pipe"] = RD["glab ci"]
  RD["glab job"] = "|artifact|"
  RD["glab release"] = "|list|ls|view|download|"
  RD["glab repo"] = "|list|ls|view|clone|search|contributors|archive|"
  RD["glab project"] = RD["glab repo"]
  RD["glab label"] = "|list|ls|get|"
  RD["glab variable"] = "|list|ls|get|export|"
  RD["glab var"] = RD["glab variable"]
  RD["glab snippet"] = "|list|ls|view|"
  RD["glab schedule"] = "|list|ls|"
  RD["glab sched"] = RD["glab schedule"]; RD["glab skd"] = RD["glab schedule"]
  RD["glab milestone"] = "|list|ls|get|"
  RD["glab incident"] = "|list|ls|view|show|"
  RD["glab token"] = "|list|ls|"
  RD["glab deploy-key"] = "|list|ls|get|"
  RD["glab ssh-key"] = "|list|ls|get|"
  RD["glab gpg-key"] = "|list|ls|get|"
  RD["glab cluster"] = "|agent list|graph|"
  RD["glab stack"] = "|list|ls|prev|next|first|last|move|create|save|amend|switch|"
  RD["glab stacks"] = RD["glab stack"]
  RD["glab securefile"] = "|list|ls|show|get|download|"
  RD["glab runner"] = "|list|ls|jobs|managers|"
  RD["glab runner-controller"] = "|list|ls|get|scope list|token list|"
  RD["glab opentofu"] = "|init|state list|state download|"
  RD["glab todo"] = "|list|ls|"
  RD["glab alias"] = "|list|ls|delete|"
  # duo cli and mcp serve run an agent or a server that can write as the owner.
  RD["glab duo"] = "|ask|"
  RD["glab mcp"] = "|"
  # glab 1.112 groups. dependency-firewall configure writes a local package
  # manager config, not the forge. orbit setup/local and skills install/update
  # install a binary or agent skills on this machine: denied, like duo cli.
  RD["glab container-registry"] = "|repository list|repository ls|repository view|tag list|tag ls|tag view|"
  RD["glab dependency-firewall"] = "|ci-summary|configure|"
  RD["glab orbit"] = "|remote dsl|remote graph-status|remote query|remote schema|remote status|remote tools|"
  RD["glab packages"] = "|list|ls|download|"
  RD["glab search"] = "|semantic|"
  RD["glab security"] = "|config status|"
  RD["glab skills"] = "|list|"
}
function valued(x) { return x == "-R" || x == "--repo" || x == "--hostname" }
# unread(v): a field value this guard cannot read: from a file (=@f), or a
# GraphQL query built by expansion (`query=$Q`, `query=$(cat f)`, backticks).
# A caller with the real argv masks every literal `$` first (to \034), as the
# hook does inside single quotes, so a GraphQL `query($o: …)` reads as text.
function unread(v) { return v ~ /=@/ || v ~ /(^|[^A-Za-z0-9_])query=.*[$]/ }
function api_write(s,    k, x, cl, c, ch, rest, v, done, method, field, ovr, ep, fromfile) {
  method = ""; field = 0; ovr = 0; ep = ""; fromfile = 0
  for (k = s; k <= n; k++) {
    x = t[k]
    if (x == "-X" || x == "--method") { method = t[k + 1]; k++; continue }
    if (x ~ /^--method=/) { method = substr(x, 10); continue }
    # A short cluster (`-iqXGET`) is read the way pflag reads it: a flag that
    # takes no value (`-i`) is skipped, and the first value option takes the
    # rest of the word (or the next word) as its value. `-qXGET` is the jq
    # filter XGET, never the method.
    if (x ~ /^-[^-]/) {
      cl = substr(x, 2); done = 0
      for (c = 1; c <= length(cl); c++) {
        ch = substr(cl, c, 1); rest = substr(cl, c + 1)
        if (ch == "X") { sub(/^=/, "", rest); if (rest == "") { method = t[k + 1]; k++ } else method = rest; done = 1; break }
        if (ch ~ /[qtpRHfF]/) {
          v = rest; if (rest == "") { v = t[k + 1]; k++ }
          if (ch == "H" && tolower(v) ~ /x-(http-)?method/) ovr = 1
          if (ch ~ /[fF]/) { field = 1; if (unread(v)) fromfile = 1 }
          done = 1; break
        }
      }
      if (done) continue
    }
    if (x == "-H" || x == "--header") { if (tolower(t[k + 1]) ~ /x-(http-)?method/) ovr = 1; k++; continue }
    if ((x ~ /^--header=/ || x ~ /^-H/) && tolower(x) ~ /x-(http-)?method/) { ovr = 1; continue }
    if (x == "-q" || x == "--jq" || x == "-t" || x == "--template" || x == "-p" || x == "--preview" || x == "--cache" || x == "--output" || valued(x)) { k++; continue }
    if (x == "--input") { field = 1; fromfile = 1; k++; continue }
    if (x ~ /^--input=/) { field = 1; fromfile = 1; continue }
    if (x == "-f" || x == "-F" || x == "--field" || x == "--raw-field" || x == "--form") { field = 1; if (unread(t[k + 1])) fromfile = 1; k++; continue }
    if (x ~ /^--(raw-field|field|form)=/ || (x ~ /^-[A-Za-z]*[fF]/ && x !~ /^--/)) { field = 1; if (unread(x)) fromfile = 1; continue }
    if (x ~ /^-/) continue
    if (ep == "") ep = x
  }
  sub(/^\//, "", ep)
  if (tolower(ep) == "graphql") return MUT || fromfile
  if (ovr) return 1
  method = toupper(method)
  if (method != "") return !(method == "GET" || method == "HEAD")
  return field
}
# judge(i): t[i] is the command word gh/glab; prints the verdict and exits on a write.
function judge(i,    cli, j, g, key, k, v1, v2, dd) {
  cli = t[i]; sub(/.*\//, "", cli)
  j = i + 1
  while (j <= n && t[j] ~ /^-/) { if (valued(t[j])) j++; j++ }
  g = t[j]
  if (g == "") return
  key = cli " " g
  if (key in AG) return
  if (g == "api") { if (api_write(j + 1)) { printf "%s\tapi\t\t\n", cli; exit } ; return }
  if (!(key in RD)) return
  v1 = ""; v2 = ""; dd = 0
  for (k = j + 1; k <= n; k++) {
    # After `--` every word is an argument, so a --help there is not help.
    if (!dd && t[k] == "--") { dd = 1; continue }
    # --help / -h is help only where the CLI (cobra/pflag) parses it as a
    # flag: right after the group, after a non-flag word, or after a
    # --flag=value. After a bare flag it may be that flag's value
    # (`--title --help` creates a PR titled --help), so it is read as one
    # (DND-1843). That denies `--web --help` too: a false deny of help.
    if (!dd && (t[k] == "--help" || t[k] == "-h")) {
      if (k == j + 1 || t[k - 1] !~ /^-/ || t[k - 1] ~ /^--[^=]+=/) { if (v2 == "") return; break }
      continue
    }
    if (!dd && t[k] ~ /^-/) { if (valued(t[k])) k++; continue }
    if (v1 == "") v1 = t[k]; else if (v2 == "") v2 = t[k]; else break
    if (v2 != "") break
  }
  if (v1 == "") return
  if (index(RD[key], "|" v1 "|") || index(RD[key], "|" v1 " " v2 "|")) return
  printf "%s\t%s\t%s\t%s\n", cli, g, v1, RD[key]
  exit
}
