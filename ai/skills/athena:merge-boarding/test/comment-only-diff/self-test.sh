#!/usr/bin/env bash
# Self-test for ai/skills/athena:merge-boarding/scripts/comment-only-diff.
# Hermetic: throwaway git repos under a temp dir; no network, no real repo.
# Elixir cases need `elixir` on PATH; without it they are asserted to exit 3
# (COULD NOT MEASURE), never skipped as a pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../../scripts" && pwd)/comment-only-diff"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# new_repo NAME: repo with one base commit holding the fixture files.
new_repo() {
  local r="${TMP}/$1"
  git init -q -b main "$r"
  git -C "$r" config user.email t@example.invalid
  git -C "$r" config user.name t
  mkdir -p "$r/lib" "$r/.github/workflows" "$r/docs/adr" "$r/tf" "$r/.claude" "$r/x/scripts"
  cat > "$r/lib/a.ex" <<'EOF'
defmodule A do
  @moduledoc """
  Docs.
  """
  def f(x), do: x + 1
end
EOF
  cat > "$r/.github/workflows/ci.yml" <<'EOF'
on:
  push:
    branches: [main]
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
  printf '# ADR 1\n\nText.\n' > "$r/docs/adr/0001.md"
  printf '# Rules\n' > "$r/CLAUDE.md"
  printf '# Skill\n' > "$r/.claude/SKILL.md"
  printf 'resource "x" "y" {}\n' > "$r/tf/main.tf"
  printf '#!/bin/sh\necho hi\n' > "$r/run.sh"
  printf 'x\n' > "$r/x/scripts/comment-only-diff"
  git -C "$r" add -A && git -C "$r" commit -q -m base
  git -C "$r" tag base
  echo "$r"
}

# run_case NAME EXPECTED_RC MUTATION [EXTRA_ENV]
run_case() {
  local name="$1" want="$2" mut="$3" envs="${4-}"
  local r; r="$(new_repo "$name")"
  ( cd "$r" && eval "$mut" ) && git -C "$r" add -A && git -C "$r" commit -q -m change --allow-empty
  local out rc
  out="$(cd "$r" && env ${envs} "${TOOL}" --base base --head HEAD 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "${name} (exit ${rc})"; else bad "${name}: expected exit ${want}, got ${rc}" "$out"; fi
}

# A usable elixir, run from a fixture dir. Under asdf a dir with no
# .tool-versions has no version, so fall back to the newest installed pair.
elixir_works() { grep -qx ok <<<"$(cd "${TMP}" && elixir -e 'IO.puts(:ok)' 2>/dev/null)"; }
has_elixir=0
if elixir_works; then has_elixir=1
elif [ -d "${ASDF_DATA_DIR:-$HOME/.asdf}/installs/elixir" ]; then
  inst="${ASDF_DATA_DIR:-$HOME/.asdf}/installs"
  ASDF_ELIXIR_VERSION="$(command ls -1 "${inst}/elixir" 2>/dev/null | sort -V | tail -1)"
  ASDF_ERLANG_VERSION="$(command ls -1 "${inst}/erlang" 2>/dev/null | sort -V | tail -1)"
  export ASDF_ELIXIR_VERSION ASDF_ERLANG_VERSION
  elixir_works && has_elixir=1
fi
ex_ok=0; ex_bad=1
if [ "$has_elixir" -eq 0 ]; then ex_ok=3; ex_bad=3; echo "note: no usable elixir; Elixir cases assert exit 3 (COULD NOT MEASURE)"; fi

run_case ex-comment-added      "$ex_ok"  'sed -i "s/^  def f/  # a comment\n  def f/" lib/a.ex'
run_case ex-trailing-comment   "$ex_ok"  'sed -i "s/x + 1$/x + 1 # inc/" lib/a.ex'
run_case ex-code-changed       "$ex_bad" 'sed -i "s/x + 1/x + 2/" lib/a.ex'
run_case ex-moduledoc-changed  "$ex_bad" 'sed -i "s/Docs\./Other docs./" lib/a.ex'
run_case ex-hash-in-heredoc    "$ex_bad" 'sed -i "s/^  Docs\.$/  Docs.\n  # not a comment, heredoc text/" lib/a.ex'
run_case ex-parse-error        "$ex_bad" 'printf "defmodule A do\n" > lib/a.ex'
run_case ex-no-elixir          3         'sed -i "s/^  def f/  # c\n  def f/" lib/a.ex' 'COMMENT_ONLY_DIFF_ELIXIR=/nonexistent/elixir'
run_case yaml-comment-added    0         'sed -i "s/^jobs:/# note\njobs:/" .github/workflows/ci.yml'
run_case yaml-key-changed      1         'sed -i "s/echo hi/echo bye/" .github/workflows/ci.yml'
run_case yaml-style-changed    1         'sed -i "s/branches: \[main\]/branches: [\"main\"]/" .github/workflows/ci.yml'
run_case yaml-trigger-added    1         'sed -i "s/^  push:/  workflow_dispatch:\n  push:/" .github/workflows/ci.yml'
run_case md-adr-changed        0         'printf "More.\n" >> docs/adr/0001.md'
run_case md-adr-added          0         'printf "# ADR 2\n" > docs/adr/0002.md'
run_case md-claude-rule-prose  1         'printf "More.\n" >> CLAUDE.md'
run_case md-dot-claude         1         'printf "More.\n" >> .claude/SKILL.md'
run_case md-mode-change        1         'chmod +x docs/adr/0001.md'
run_case tf-needs-plan         5         'printf "# comment\n" >> tf/main.tf'
run_case tf-slash-comment      5         'printf "\n// comment\n" >> tf/main.tf'
# A no-change plan does not prove a comment-only edit: removing
# prevent_destroy, a moved/removed block, or a provider constraint plans
# nothing. Non-comment lines must be identical before a plan is asked for.
run_case tf-code-changed       1         'printf "resource \"x\" \"y\" {\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n" > tf/main.tf'
run_case tf-trailing-comment   1         'sed -i "s/{}/{} # note/" tf/main.tf'
run_case tf-block-comment      1         'printf "/* c */\n" >> tf/main.tf'
run_case tf-heredoc            1         'printf "locals {\n  s = <<EOT\n# x\nEOT\n}\n" >> tf/main.tf; git add -A; git commit -q -m h; git tag -f base >/dev/null; printf "# y\n" >> tf/main.tf'
# Inside a /* */ block a `#` means nothing, so a `#` line can close the block:
# editing it moves the block's end and comments out code with every
# non-comment line unchanged. Any block-comment marker on either side: refused.
run_case tf-hash-in-block      1         'printf "/* a\n# */\nlocals { p = true }\n/* b */\n" >> tf/main.tf; git add -A; git commit -q -m b; git tag -f base >/dev/null; sed -i "s|^# \*/$|#|" tf/main.tf'
run_case tf-lockfile          1         'printf "# lock\n" > tf/.terraform.lock.hcl; git add -A; git commit -q -m l; git tag -f base >/dev/null; printf "# comment\n" >> tf/.terraform.lock.hcl'
# A comment a tool reads as a suppression directive weakens a check: it is
# not "only a comment". A directive's reach (next line, region, counted span)
# is each tool's own grammar, and a comment edit near one can change it, so a
# file with a directive on either side is not judged (NOT covered, exit 1,
# whether or not elixir is installed).
EX_TWO='defmodule A do\n  # credo:disable-for-next-line X\n  def f(x), do: x + 1\n  def g(x), do: x\nend\n'
EX_MOVED='defmodule A do\n  def f(x), do: x + 1\n  # credo:disable-for-next-line X\n  def g(x), do: x\nend\n'
EX_NOTE='defmodule A do\n  # credo:disable-for-next-line X\n  def f(x), do: x + 1\n  # a note\n  def g(x), do: x\nend\n'
# credo:disable-for-lines:3 covers a counted span: deleting two comment lines
# inside it pulls `def bad` into the span with the AST and neighbour unchanged.
EX_SPAN='defmodule A do\n  # credo:disable-for-lines:3 X\n  def f(x), do: x\n  # note\n  # note\n  def bad(x), do: x\nend\n'
run_case ex-suppress-moved     1         "printf '${EX_TWO}' > lib/a.ex; git add -A; git commit -q -m m; git tag -f base >/dev/null; printf '${EX_MOVED}' > lib/a.ex"
run_case ex-suppress-present   1         "printf '${EX_TWO}' > lib/a.ex; git add -A; git commit -q -m m; git tag -f base >/dev/null; printf '${EX_NOTE}' > lib/a.ex"
run_case ex-suppress-span-widened 1      "printf '${EX_SPAN}' > lib/a.ex; git add -A; git commit -q -m m; git tag -f base >/dev/null; sed -i '/# note/d' lib/a.ex"
run_case ex-region-stop-removed 1        'printf "defmodule A do\n  # coveralls-ignore-start\n  def f(x), do: x\n  # coveralls-ignore-stop\n  def g(x), do: x\nend\n" > lib/a.ex; git add -A; git commit -q -m r; git tag -f base >/dev/null; sed -i "/coveralls-ignore-stop/d" lib/a.ex'
run_case tf-suppress-moved     1         'printf "# tfsec:ignore:x\nresource \"a\" \"b\" {}\nresource \"c\" \"d\" {}\n" > tf/main.tf; git add -A; git commit -q -m t; git tag -f base >/dev/null; printf "resource \"a\" \"b\" {}\n# tfsec:ignore:x\nresource \"c\" \"d\" {}\n" > tf/main.tf'
run_case yaml-suppress-added   1         'sed -i "s/^jobs:/# zizmor: ignore[unpinned-uses]\njobs:/" .github/workflows/ci.yml'
run_case tf-suppress-added     1         'printf "# tfsec:ignore:aws-s3-enable-versioning\n" >> tf/main.tf'
run_case ex-suppress-added     1         'sed -i "s/^  def f/  # credo:disable-for-this-file\n  def f/" lib/a.ex'
run_case md-suppress-added     1         'printf "<!-- markdownlint-disable -->\n" >> docs/adr/0001.md'
run_case yaml-suppress-removed 1        'sed -i "s/^jobs:/# nosemgrep\njobs:/" .github/workflows/ci.yml; git add -A; git commit -q -m d; git tag -f base >/dev/null; sed -i "/nosemgrep/d" .github/workflows/ci.yml'
run_case shell-unsupported     1         'printf "# comment\n" >> run.sh'
run_case new-code-file         1         'printf "defmodule B do\nend\n" > lib/b.ex'
run_case deleted-code-file     1         'rm lib/a.ex'
run_case self-protection       1         'printf "y\n" > x/scripts/comment-only-diff'
run_case mixed-doc-and-code    1         'printf "More.\n" >> docs/adr/0001.md; printf "# c\n" >> run.sh'
run_case empty-diff            2         'true'

# Unresolvable ref: exit 2 with a Fix: line.
r="$(new_repo badref)"
out="$(cd "$r" && "${TOOL}" --base nope --head HEAD 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '^Fix:' <<<"$out"; then ok "bad-ref (exit 2, Fix:)"; else bad "bad-ref: expected exit 2 + Fix:, got ${rc}" "$out"; fi

# Reads objects, not the worktree: an uncommitted code edit is invisible.
r="$(new_repo worktree-ignored)"
printf "# ADR\n" >> "$r/docs/adr/0001.md"; git -C "$r" commit -q -am doc
sed -i 's/x + 1/x + 9/' "$r/lib/a.ex"
out="$(cd "$r" && "${TOOL}" --base base --head HEAD 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "reads git objects, not the dirty worktree" || bad "worktree-ignored: expected 0, got ${rc}" "$out"

# --help: stdout, exit 0.
out="$("${TOOL}" --help)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Usage:' <<<"$out"; then ok "--help"; else bad "--help" "$out"; fi

echo "comment-only-diff self-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
