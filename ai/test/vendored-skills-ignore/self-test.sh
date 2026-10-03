#!/usr/bin/env bash
# Self-test for the repo .gitignore's third-party skill block (DND-1960) --
# discovered and run by harness-gate.
#
# The defect this pins: the HyperFrames plugin's skill installer
# (`npx hyperframes skills update <name>`) copies its skills into
# ~/.claude/skills, which resolves to the MAIN checkout's ai/skills/. Nothing
# ignored them, so on 2026-10-03 eleven untracked skill dirs (406 files):
#   - dirtied the main checkout, so every shipwright tick yielded (DND-692);
#   - read as first-party code to the checks that list untracked files with
#     `git ls-files --others --exclude-standard`: check-guard-messages failed
#     on 14 unclassified media-use/scripts/lib/*.mjs, and check-bin-help and
#     check-tool-risk (ai/lib/harness_tools.rb over ai/lib/first_party.rb)
#     failed on media-use/audio/scripts/heygen-tts.mjs, an executable under
#     the ai/skills/*/scripts/* harness-tool scope with no --help branch.
#
# Every case builds a throwaway repo holding only this checkout's .gitignore
# plus one first-party tool, then writes the installer's dirs into it the way
# the installer does (untracked, executable scripts, a nested .gitignore). It
# reads the .gitignore under test from the working tree, so it runs unchanged
# against the pre-fix file, which is how the fail-first evidence was recorded:
#
#   VENDORED_SKILLS_GITIGNORE_UNDER_TEST=/path/to/old/.gitignore \
#     ai/test/vendored-skills-ignore/self-test.sh
#
# The negative cases are the reason the block is an explicit list: a broad
# `ai/skills/*` (or `ai/skills/hyperframes*`) pattern would also hide a NEW
# first-party skill, and `git add -A` would skip it with no error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
REPO_DIR="$(cd "${AI_DIR}/.." && pwd)"
GITIGNORE="${VENDORED_SKILLS_GITIGNORE_UNDER_TEST:-${REPO_DIR}/.gitignore}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  # The header comment, up to the first non-comment line.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 0
fi

if [ ! -f "${GITIGNORE}" ]; then
  echo "vendored-skills-ignore self-test: FAIL -- ${GITIGNORE} does not exist" >&2
  echo "Fix: point VENDORED_SKILLS_GITIGNORE_UNDER_TEST at a real .gitignore, or restore the repo's .gitignore." >&2
  exit 1
fi

# The skill names in ~/.agents/.skill-lock.json (`.skills` keys) as the
# installer left it on 2026-10-03, v0.8.116. Keep this list and the
# .gitignore block in step: a name dropped from .gitignore fails here, but a
# name added only to .gitignore is not tested.
VENDORED=(
  faceless-explainer hyperframes hyperframes-animation hyperframes-audio
  hyperframes-cli hyperframes-core hyperframes-creative hyperframes-keyframes
  hyperframes-registry hyperframes-studio media-use
)

TMP="$(mktemp -d -t 'vendored-skills-ignore.XXXXXXXXXX')"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# A hermetic git: only the repo .gitignore under test may ignore the dirs, or
# the test passes on a machine whose repo still does not.
#   - GIT_CONFIG_GLOBAL replaces the config FILE only; git still reads its
#     default excludes file ($XDG_CONFIG_HOME/git/ignore) unless
#     core.excludesFile names another, so it is pinned to /dev/null.
#   - Inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_COMMON_DIR (a git
#     hook's env) would aim `git -C fixture` at the caller's repo, and
#     GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS can inject an excludes file.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[core]\n\texcludesFile = /dev/null\n' > "${GIT_CONFIG_GLOBAL}"

FX="${TMP}/repo"
mkdir -p "${FX}/ai/bin" "${FX}/ai/lib"
git -C "${FX}" init -q || { echo "vendored-skills-ignore self-test: FAIL -- git init failed" >&2; echo "Fix: make git available on PATH." >&2; exit 1; }
cp "${GITIGNORE}" "${FX}/.gitignore"
cp "${AI_DIR}/lib/first_party.rb" "${AI_DIR}/lib/harness_tools.rb" "${FX}/ai/lib/"
printf '#!/bin/sh\ncase "${1:-}" in -h|--help) echo usage; exit 0 ;; esac\n' > "${FX}/ai/bin/first-party-tool"
chmod +x "${FX}/ai/bin/first-party-tool"
if ! { git -C "${FX}" add -A && git -C "${FX}" commit -qm fixture; }; then
  echo "vendored-skills-ignore self-test: FAIL -- could not commit the fixture repo in ${FX}" >&2
  echo "Fix: make git able to commit in a temp dir (user.name/email come from the fixture gitconfig)." >&2
  exit 1
fi

# ignored <rel>: 0 ignored, 1 not ignored, 2 git could not answer (exit 128).
# A git error must never read as "no rule matches".
ignored() {
  git -C "${FX}" check-ignore -q "$1" 2>/dev/null
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# Write the dirs the way the installer does: SKILL.md, an executable script
# with no --help branch (heygen-tts.mjs's shape), sourced lib code, and
# media-use's own nested .gitignore.
for name in "${VENDORED[@]}"; do
  d="${FX}/ai/skills/${name}"
  mkdir -p "${d}/scripts/lib" "${d}/audio/scripts"
  printf -- '---\nname: %s\n---\n' "${name}" > "${d}/SKILL.md"
  printf '#!/usr/bin/env node\nconsole.log("default action")\n' > "${d}/audio/scripts/tts.mjs"
  chmod +x "${d}/audio/scripts/tts.mjs"
  printf 'export const x = 1\n' > "${d}/scripts/lib/util.mjs"
done
printf 'node_modules/\n' > "${FX}/ai/skills/media-use/.gitignore"

# --- case 1: the installer's dirs leave the tree clean ----------------------
status="$(git -C "${FX}" status --porcelain -uall 2>&1)"
if [ -z "${status}" ]; then
  ok "installer-written skill dirs leave git status clean"
else
  bad "installer-written skill dirs leave git status clean" \
      "git status --porcelain -uall: $(printf '%s' "${status}" | head -5 | tr '\n' ' ')"
fi

# --- case 2: each name is ignored (named per skill, so a miss says which) ---
for name in "${VENDORED[@]}"; do
  ignored "ai/skills/${name}/SKILL.md"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    ok "ai/skills/${name}/ is git-ignored"
  elif [ "${rc}" -eq 1 ]; then
    bad "ai/skills/${name}/ is git-ignored" \
        "no .gitignore rule matches ai/skills/${name}/SKILL.md; add '/ai/skills/${name}/' to the third-party skill block"
  else
    bad "ai/skills/${name}/ is git-ignored" \
        "git check-ignore could not answer for ai/skills/${name}/SKILL.md (exit 128)"
  fi
done

# --- case 3: check-guard-messages' untracked listing is empty ---------------
others="$(git -C "${FX}" ls-files --others --exclude-standard 2>&1)"
if [ -z "${others}" ]; then
  ok "git ls-files --others --exclude-standard lists no installer file"
else
  bad "git ls-files --others --exclude-standard lists no installer file" \
      "listed: $(printf '%s' "${others}" | head -5 | tr '\n' ' ')"
fi

# --- case 4: the harness-tool scope (check-bin-help, check-tool-risk) -------
tools="$(ruby -e '
  require ARGV[0] + "/ai/lib/harness_tools"
  r = HarnessTools.discover(ARGV[0])
  puts r.tools
  puts r.unscoped.map { |p| "unscoped:" + p }
' "${FX}" 2>&1)"
if [ "${tools}" = "ai/bin/first-party-tool" ]; then
  ok "HarnessTools.discover finds the first-party tool and no installer script"
else
  bad "HarnessTools.discover finds the first-party tool and no installer script" \
      "discovered: $(printf '%s' "${tools}" | head -5 | tr '\n' ' ')"
fi

# --- case 5: a NEW first-party skill is NOT hidden --------------------------
# Both a fresh name and one sharing the installer's prefix: a broad pattern
# (`ai/skills/*`, `ai/skills/hyperframes*`) in place of the explicit list would
# swallow either, silently. A narrower pattern written to dodge these two names
# would pass; the block's own comment forbids patterns.
for name in "athena:brand-new-skill" "hyperframes-future"; do
  mkdir -p "${FX}/ai/skills/${name}"
  printf -- '---\nname: %s\n---\n' "${name}" > "${FX}/ai/skills/${name}/SKILL.md"
  ignored "ai/skills/${name}/SKILL.md"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    bad "a new first-party skill ai/skills/${name}/ stays visible" \
        "git check-ignore could not answer for ai/skills/${name}/SKILL.md (exit 128)"
  elif [ "${rc}" -eq 0 ]; then
    bad "a new first-party skill ai/skills/${name}/ stays visible" \
        "it is git-ignored, so 'git add -A' would skip it with no error; list third-party skills one per line, never by pattern"
  elif grep -qF "ai/skills/${name}/SKILL.md" <<<"$(git -C "${FX}" status --porcelain -uall)"; then
    ok "a new first-party skill ai/skills/${name}/ stays visible"
  else
    bad "a new first-party skill ai/skills/${name}/ stays visible" \
        "not ignored, yet git status does not list it"
  fi
done

echo
echo "vendored-skills-ignore self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Fix: list each third-party skill dir the installer writes (the .skills keys of ~/.agents/.skill-lock.json) as its own '/ai/skills/<name>/' line in the repo .gitignore's third-party skill block; never a pattern that could match a first-party skill." >&2
  exit 1
fi
exit 0
