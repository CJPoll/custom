#!/usr/bin/env bash
# Self-test for ai/lib/forge-identity.sh (DND-1936): which Athena bot acts on
# a GitLab project, keyed on (host, top-level namespace).
#
# The defect this pins: glab-athena, forge-preflight and push-actor-check
# hard-coded ONE bot for every gitlab.com project. With a work group and a
# personal namespace (cjpoll/ in these fixtures; athena-ai-harness/ in the
# tracked map) on the same host, a push to a personal project would have gone
# out as the work bot. Each identity must resolve for its own
# namespace, and every wrongly computed key (an SSH remote form, a different
# case, a subgroup path, no namespace, an unknown host) and every missing map
# half must be a NAMED refusal, never the other identity.
#
# Hermetic: a fixture public map (ATHENA_FORGE_IDENTITIES_FILE) and a fixture
# private overlay (ATHENA_PRIVATE_ROOT); synthetic names only. No network.
# Gated: harness-gate runs every tracked **/self-test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
LIB="${FORGE_IDENTITY_LIB_UNDER_TEST:-${AI_DIR}/lib/forge-identity.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"
export HOME="${TMP}/home"; mkdir -p "${HOME}"

P_BOT="synthetic-personal-bot" W_BOT="synthetic-work-bot" W_NS="synthetic-work-group"

MAP="${TMP}/forge-identities.json"
write_map() { # [bot-json]
  cat > "${MAP}" <<EOF
{"kind":"athena-forge-identities","schema":1,"identities":[
 {"host":"gitlab.com","namespace":"cjpoll","bot":${1:-\"${P_BOT}\"},"pending":"synthetic pending reason","token_file":"~/.claude/personal-token","refresh":"self_rotate"}]}
EOF
}
write_map
OV="${TMP}/overlay"; mkdir -p "${OV}/overlay"; chmod 700 "${OV}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OV}/athena-overlay.json"
write_ov() { # <identities-json>
  printf '{"group":"%s","identities":%s}\n' "${W_NS}" "$1" > "${OV}/overlay/gitlab.json"
}
W_ENTRY="{\"host\":\"gitlab.com\",\"namespace\":\"${W_NS}\",\"bot\":\"${W_BOT}\",\"token_file\":\"/abs/work-token\",\"refresh\":\"group_service_account\"}"
write_ov "[${W_ENTRY}]"
export ATHENA_FORGE_IDENTITIES_FILE="${MAP}" ATHENA_PRIVATE_ROOT="${OV}"

# fid <function> <args...> : run one lib function in a fresh shell; prints
# rc|state|bot|token|why|fix.
fid() {
  bash -c '. "$1"; shift; f="$1"; shift; "$f" "$@"; rc=$?
    printf "%s|%s|%s|%s|%s|%s" "$rc" "$FID_STATE" "$FID_BOT" "$FID_TOKEN_FILE" "$FID_WHY" "$FID_FIX"' _ "${LIB}" "$@"
}
# fid_in <dir> <function> <args...> : the same, run in <dir>.
fid_in() { local d="$1"; shift; ( cd "$d" && fid "$@" ); }

R="" ; f_rc() { printf '%s' "${R%%|*}"; }
field() { printf '%s' "${R}" | cut -d'|' -f"$1"; }
# expect <id> <label> <rc> <state> <bot or -> <must-contain or ->
expect() {
  local id="$1" label="$2" rc="$3" st="$4" b="$5" want="$6"
  if [ "$(f_rc)" = "$rc" ] && [ "$(field 2)" = "$st" ] && { [ "$b" = - ] || [ "$(field 3)" = "$b" ]; } \
    && { [ "$want" = - ] || [[ "$R" == *"$want"* ]]; } \
    && { [ "$rc" = 0 ] || [[ "$(field 6)" == *"Never fall back"* ]]; }; then ok "${id}. ${label}"
  else bad "${id}. ${label}" "got '${R}'"; fi
}
# neither_bot <id> <label> : a refusal hands out no bot at all.
neither_bot() {
  if [ "$(f_rc)" != 0 ] && [ -z "$(field 3)" ] && [ -z "$(field 4)" ]; then ok "$1. $2"
  else bad "$1. $2" "got '${R}'"; fi
}

echo "forge-identity self-test"
echo "lib: ${LIB}"
echo
echo "--- HIT: each identity resolves for its own namespace ---"
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect H1 "https cjpoll/custom -> the personal bot, its token file under HOME" 0 FOUND "${P_BOT}" "${HOME}/.claude/personal-token"
R="$(fid fid_resolve_url "https://gitlab.com/${W_NS}/app.git")"
expect H2 "https work project -> the work bot from the overlay" 0 FOUND "${W_BOT}" "/abs/work-token"
R="$(fid fid_resolve_url git@gitlab.com:cjpoll/gen_saas.git)"
expect H3 "scp-like SSH remote git@gitlab.com:cjpoll/... parses to the personal key" 0 FOUND "${P_BOT}" -
R="$(fid fid_resolve_url "ssh://git@GitLab.com:2222/${W_NS}/app.git/")"
expect H4 "ssh:// with a port, a mixed-case host and a trailing .git/ -> the work bot" 0 FOUND "${W_BOT}" -
R="$(fid fid_resolve_url "https://gitlab.com/${W_NS}/sub/deeper/app.git")"
expect H5 "a project in a work subgroup keys on the top-level namespace" 0 FOUND "${W_BOT}" -

echo
echo "--- MISS: a wrongly computed key is a NAMED refusal, never the other bot ---"
R="$(fid fid_lookup git@gitlab.com cjpoll)"
expect K1 "host 'git@gitlab.com' (an SSH remote form) -> BAD KEY naming it" 2 "BAD KEY" "" "SSH remote form"; neither_bot K1b "no bot handed out"
R="$(fid fid_lookup gitlab.com git@gitlab.com:cjpoll)"
expect K2 "namespace 'git@gitlab.com:cjpoll' (an SSH remote form) -> BAD KEY" 2 "BAD KEY" "" "SSH remote form"
R="$(fid fid_lookup gitlab.com CJPoll)"
expect K3 "namespace 'CJPoll' (different case) -> NO ENTRY, names the canonical 'cjpoll'" 1 "NO ENTRY" "" "differs only in case"; neither_bot K3b "no bot handed out"
R="$(fid fid_resolve_url https://gitlab.com/CJPoll/custom.git)"
expect K3c "a remote spelled CJPoll/custom -> NO ENTRY, not the personal bot" 1 "NO ENTRY" "" "gitlab.com/CJPoll"
R="$(fid fid_lookup gitlab.com "${W_NS}/sub")"
expect K4 "namespace '<group>/sub' (a subgroup path) -> BAD KEY" 2 "BAD KEY" "" "subgroup or project path"
R="$(fid fid_lookup gitlab.com cjpoll/custom)"
expect K4b "namespace 'cjpoll/custom' (a project path) -> BAD KEY, not the personal bot" 2 "BAD KEY" "" "TOP-LEVEL"
R="$(fid fid_resolve_url https://gitlab.com/custom.git)"
expect K5 "a remote with no namespace -> BAD KEY" 2 "BAD KEY" "" "names no <namespace>/<project>"
R="$(fid fid_lookup gitlab.com "")"
expect K5b "an empty namespace -> BAD KEY" 2 "BAD KEY" "" "no namespace"
R="$(fid fid_resolve_url https://gitlab.example.com/cjpoll/custom.git)"
expect K6 "an unknown host -> NO ENTRY naming host and namespace" 1 "NO ENTRY" "" "gitlab.example.com/cjpoll"
R="$(fid fid_lookup GITLAB.com cjpoll)"
expect K7 "an upper-case host passed as the key -> BAD KEY (not lower-cased on the lookup side)" 2 "BAD KEY" "" "not lower case"
R="$(fid fid_resolve_url "https://gitlab.com/otherns/app.git")"
expect K8 "a namespace with no entry -> NO ENTRY naming both halves searched" 1 "NO ENTRY" "" "private overlay's gitlab .identities [PRESENT"
R="$(fid fid_resolve_url /local/path/repo.git)"
expect K9 "a local path -> BAD KEY" 2 "BAD KEY" "" "local path"
R="$(fid fid_resolve_url "")"
expect K10 "an empty remote -> BAD KEY" 2 "BAD KEY" "" "empty"
R="$(fid fid_resolve_url "https://user:s3cr3t@gitlab.com/custom.git")"
if [ "$(f_rc)" = 2 ] && [[ "$R" == *"https://gitlab.com/custom.git"* ]] && [[ "$R" != *s3cr3t* ]]; then
  ok "K11. a refusal names the remote without its user:password@"
else bad "K11. credential kept out of the refusal" "got '${R}'"; fi
R="$(fid fid_resolve_url "https://user:s3cr3t@gitlab.com/cjpoll/custom.git")"
expect K12 "credentials in the URL change no key: still the personal bot" 0 FOUND "${P_BOT}" -

echo
echo "--- the map's two halves: missing, unreadable or conflicting is never a quiet miss ---"
R="$(unset ATHENA_PRIVATE_ROOT; fid fid_resolve_url "https://gitlab.com/${W_NS}/app.git")"
expect M1 "work remote, overlay ABSENT -> NO ENTRY that says the overlay is absent" 1 "NO ENTRY" "" "ABSENT"; neither_bot M1b "the work remote does not get the personal bot"
R="$(unset ATHENA_PRIVATE_ROOT; fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M2 "personal remote, overlay ABSENT -> still the personal bot" 0 FOUND "${P_BOT}" -
printf '{"group":"%s"}\n' "${W_NS}" > "${OV}/overlay/gitlab.json"
R="$(fid fid_resolve_url "https://gitlab.com/${W_NS}/app.git")"
expect M3 "overlay present with no .identities key -> NO ENTRY that says so" 1 "NO ENTRY" "" "no gitlab .identities key"
write_ov "[${W_ENTRY}]"
BAD_OV="${TMP}/bad-overlay"; mkdir -p "${BAD_OV}/overlay"; chmod 700 "${BAD_OV}"
printf '{"kind":"something-else","schema":1}\n' > "${BAD_OV}/athena-overlay.json"
R="$(ATHENA_PRIVATE_ROOT="${BAD_OV}" fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M4 "a MALFORMED overlay -> COULD NOT LOOK, even for the personal namespace" 3 "COULD NOT LOOK" "" "MALFORMED"
R="$(ATHENA_FORGE_IDENTITIES_FILE="${TMP}/no-such-map.json" fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M5 "an unreadable public map -> COULD NOT LOOK naming the file" 3 "COULD NOT LOOK" "" "no-such-map.json"
printf 'not json' > "${TMP}/garbage.json"
R="$(ATHENA_FORGE_IDENTITIES_FILE="${TMP}/garbage.json" fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M6 "a public map that is not JSON -> COULD NOT LOOK" 3 "COULD NOT LOOK" "" "not a JSON object"
write_map '"bad user name"'
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M7 "an entry whose bot is not a username -> COULD NOT LOOK naming the entry" 3 "COULD NOT LOOK" "" "public entry 0"
write_map
write_ov "[${W_ENTRY},{\"host\":\"gitlab.com\",\"namespace\":\"CJPOLL\",\"bot\":\"${W_BOT}\",\"token_file\":\"/abs/work-token\",\"refresh\":\"group_service_account\"}]"
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M8 "an overlay entry claiming cjpoll (any case) -> COULD NOT LOOK, never the work bot" 3 "COULD NOT LOOK" "" "two entries claim"
write_ov "[{\"host\":\"gitlab.com\",\"namespace\":\"${W_NS}\",\"bot\":\"${W_BOT}\",\"token_file\":\"~/.claude/personal-token\",\"refresh\":\"group_service_account\"}]"
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M9 "two bots sharing one token file -> COULD NOT LOOK" 3 "COULD NOT LOOK" "" "share the token file"
write_ov "[${W_ENTRY}]"
write_map null
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M10 "an entry with bot null -> PENDING with its reason, no bot" 4 PENDING "" "synthetic pending reason"; neither_bot M10b "no bot handed out"
write_map
# The tracked map (owner decision, 2026-10-05): the personal bot is the
# athena-ai-harness group's service account, and cjpoll/ has no bot, because
# that bot is a member of the group only.
R="$(ATHENA_FORGE_IDENTITIES_FILE= fid fid_resolve_url https://gitlab.com/athena-ai-harness/gen_saas.git)"
expect M11 "the tracked map: athena-ai-harness/ -> athena-ai-harness-bot, its token file under HOME" 0 FOUND athena-ai-harness-bot "${HOME}/.claude/gitlab-personal-athena-token"
R="$(ATHENA_FORGE_IDENTITIES_FILE= fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect M11b "the tracked map: cjpoll/ is PENDING (the group bot cannot write there), its reason and Fix: given" 4 PENDING "" "member of the athena-ai-harness group only"; neither_bot M11c "cjpoll/ is never handed the group bot"
R="$(ATHENA_FORGE_IDENTITIES_FILE= fid fid_resolve_url https://gitlab.com/Athena-AI-Harness/gen_saas.git)"
expect M11d "the tracked map: a case variant of athena-ai-harness -> NO ENTRY naming the canonical path, not the bot" 1 "NO ENTRY" "" "canonical path 'athena-ai-harness'"

echo
echo "--- glab's own arguments: -R, the api endpoint, origin ---"
mkrepo() { git init -q "${TMP}/$1"; git -C "${TMP}/$1" remote add origin "$2"; printf '%s' "${TMP}/$1"; }
PERS="$(mkrepo pers https://gitlab.com/cjpoll/custom.git)"
WORK="$(mkrepo work "git@gitlab.com:${W_NS}/app.git")"
mkdir -p "${TMP}/norepo"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create --fill)"
expect G1 "no -R: the identity of the checkout's origin (personal)" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R "${W_NS}/app" create --fill)"
expect G2 "-R <work>/<p> from a personal checkout -> the work bot (-R wins)" 0 FOUND "${W_BOT}" -
R="$(fid_in "${WORK}" fid_resolve_glab_args --repo=cjpoll/custom mr list)"
expect G3 "--repo=cjpoll/custom from a work checkout -> the personal bot" 0 FOUND "${P_BOT}" -
R="$(fid_in "${TMP}/norepo" fid_resolve_glab_args api -X POST "projects/${W_NS}%2Fapp/merge_requests/1/notes" -f body=x)"
expect G4 "api projects/<work>%2F<p>/... outside any checkout -> the work bot" 0 FOUND "${W_BOT}" -
R="$(fid_in "${TMP}/norepo" fid_resolve_glab_args api user)"
expect G5 "no -R, no endpoint project, no origin -> COULD NOT LOOK" 3 "COULD NOT LOOK" "" "no -R/--repo and no origin"
R="$(fid_in "${PERS}" fid_resolve_glab_args -R cjpoll/custom api "projects/${W_NS}%2Fapp/issues")"
expect G6 "-R and the api endpoint name different namespaces -> BAD KEY" 2 "BAD KEY" "" "api endpoint names"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R cjpoll/custom list -R "${W_NS}/app")"
expect G7 "two different -R values -> BAD KEY" 2 "BAD KEY" "" "more than once"
R="$(fid_in "${PERS}" fid_resolve_glab_args api --hostname gitlab.example.com user)"
expect G8 "--hostname of an unknown host -> NO ENTRY naming that host" 1 "NO ENTRY" "" "gitlab.example.com/cjpoll"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R gitlab.com/cjpoll/custom list)"
expect G9 "-R HOST/OWNER/REPO (ambiguous with GROUP/SUB/REPO) -> BAD KEY" 2 "BAD KEY" "" "could be HOST/OWNER/REPO"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R https://gitlab.com/cjpoll/custom list)"
expect G10 "-R as a full URL -> parsed as a remote" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R cjpoll list)"
expect G11 "-R with no project part -> BAD KEY" 2 "BAD KEY" "" "names no <namespace>/<project>"
git -C "${PERS}" remote add fork https://gitlab.com/someone-else/custom.git
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list)"
expect G12 "a second remote with no Athena identity -> BAD KEY (glab could act on it with origin's bot), pass -R" 2 "BAD KEY" "" "'fork': it is gitlab.com/someone-else"
git -C "${PERS}" remote remove fork
write_ov "[${W_ENTRY},{\"host\":\"gitlab.com\",\"namespace\":\"${W_NS}-two\",\"bot\":\"${W_BOT}\",\"token_file\":\"/abs/work-token\",\"refresh\":\"group_service_account\"}]"
git -C "${WORK}" remote add other "https://gitlab.com/${W_NS}-two/app.git"
R="$(fid_in "${WORK}" fid_resolve_glab_args mr list)"
expect G12b "a second remote whose namespace maps to the SAME bot and token is not ambiguous" 0 FOUND "${W_BOT}" -
git -C "${WORK}" remote set-url other "https://gitlab.com/$(printf '%s' "${W_NS}" | tr a-z A-Z)-TWO/app.git"
R="$(fid_in "${WORK}" fid_resolve_glab_args mr list)"
expect G12c "... matched case-insensitively, as GitLab paths are" 0 FOUND "${W_BOT}" -
git -C "${WORK}" remote remove other
write_ov "[${W_ENTRY}]"
git -C "${PERS}" remote add upstream "https://gitlab.com/${W_NS}/custom.git"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list)"
expect G13 "a second remote that is ANOTHER bot's namespace -> BAD KEY, pass -R" 2 "BAD KEY" "" "'upstream': it is gitlab.com/${W_NS}"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr -R cjpoll/custom list)"
expect G14 "the same checkout with -R -> resolves (the explicit project wins)" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/123/merge_requests")"
expect G15 "an api project named by a numeric id -> BAD KEY (it says nothing about its namespace)" 2 "BAD KEY" "" "numeric id"
R="$(fid_in "${PERS}" fid_resolve_glab_args -R cjpoll/custom api "projects/123/notes")"
expect G15b "... even with -R (the id could be any project)" 2 "BAD KEY" "" "numeric id"
git -C "${PERS}" remote set-url upstream "https://gitlab.com/$(printf '%s' "${W_NS}" | tr a-z A-Z)/custom.git"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list)"
expect G15c "a second remote naming another bot's namespace in other case -> BAD KEY" 2 "BAD KEY" "" "'upstream': it is gitlab.com/"
git -C "${PERS}" remote set-url upstream /some/local/path.git
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list)"
expect G15d "a local-path remote is no forge project and is skipped" 0 FOUND "${P_BOT}" -
git -C "${PERS}" remote set-url upstream "not a url"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list)"
expect G15e "a remote that cannot be parsed -> BAD KEY, never skipped" 2 "BAD KEY" "" "cannot be parsed"
git -C "${PERS}" remote remove upstream

echo
echo "--- a word glab reads differently from this resolver never picks the bot ---"
R="$(fid_in "${PERS}" fid_resolve_glab_args api -R cjpoll/custom "projects/${W_NS}%2Fapp/merge_requests")"
expect A1 "-R written AFTER api does not hide the endpoint: -R vs endpoint disagree -> BAD KEY" 2 "BAD KEY" "" "api endpoint names"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr note 1 -m "-R${W_NS}/y")"
expect A2 "-m -R<work>/y (a message that looks like -R) -> BAD KEY, never the work bot" 2 "BAD KEY" "" "right after the flag '-m'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr note 1 --message -R "${W_NS}/y")"
expect A3 "--message -R <work>/y -> BAD KEY" 2 "BAD KEY" "" "right after the flag '--message'"
# glab's flag parser (pflag) reads combined shorthand: in `-yR x/y` the -y is a
# boolean and -R takes the next word; in `-fRx/y` it takes the rest of the word.
R="$(fid_in "${PERS}" fid_resolve_glab_args mr merge 1 -yR "${W_NS}/y")"
expect A3b "-yR <work>/y (-R combined with a short flag) -> BAD KEY, never origin's bot" 2 "BAD KEY" "" "combined with other short flags"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create -fR"${W_NS}/y")"
expect A3c "-fR<work>/y (-R and its value combined with a short flag) -> BAD KEY" 2 "BAD KEY" "" "combined with other short flags"
R="$(fid_in "${PERS}" fid_resolve_glab_args api -X POST --hostname gitlab.example.com user)"
expect A4 "--hostname right after a valued flag's value is fine (it is after a value word)" 1 "NO ENTRY" "" "gitlab.example.com/cjpoll"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list --draft --hostname gitlab.com)"
expect A5 "--hostname right after a flag -> BAD KEY (it may be that flag's value)" 2 "BAD KEY" "" "right after the flag '--draft'"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "groups/${W_NS}/issues")"
expect A6 "api groups/<work>/... -> the work bot" 0 FOUND "${W_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api "groups/42/issues")"
expect A7 "api groups/<numeric id> -> BAD KEY" 2 "BAD KEY" "" "numeric id"
R="$(fid_in "${PERS}" fid_resolve_glab_args api graphql -f query=x)"
expect A8 "api graphql with no -R -> BAD KEY (the target is inside the query)" 2 "BAD KEY" "" "api graphql"
R="$(fid_in "${PERS}" fid_resolve_glab_args -R cjpoll/custom api graphql -f query=x)"
expect A9 "-R <p> api graphql -> the -R project's bot" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api "https://gitlab.com/api/v4/projects/${W_NS}%2Fy")"
expect A10 "an absolute-URL endpoint -> BAD KEY" 2 "BAD KEY" "" "absolute URL"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/${W_NS}%252Fy/issues")"
expect A11 "a double-encoded endpoint project -> BAD KEY" 2 "BAD KEY" "" "URL-encoded beyond"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "api/v4/projects/123/notes")"
expect A11b "an api/v4/ prefix is read through: a numeric id behind it -> BAD KEY" 2 "BAD KEY" "" "numeric id"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "API/V4/projects/${W_NS}%2Fapp/notes")"
expect A11c "... and a path behind it keys normally" 0 FOUND "${W_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api "api/v4/./projects/123/notes")"
expect A11d "a '.' segment anywhere in an endpoint -> BAD KEY" 2 "BAD KEY" "" "'.' segment"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "%70rojects/123/notes")"
expect A11e "a %-encoded route word (hiding projects/) -> BAD KEY" 2 "BAD KEY" "" "%-encoded"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/${W_NS}%2Fapp/%6derge")"
expect A11f "%-encoding past the project path -> BAD KEY" 2 "BAD KEY" "" "past its project path"
# GitLab's own routes encode a file path or a branch name with %2F past the
# project path (repository/files/:file_path, repository/branches/:branch). The
# project segment alone picks the bot, so those key on it.
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/:id/repository/files/lib%2Fa.ex?ref=main")"
expect A11g "a %2F-encoded file path past :id -> origin's bot" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api -X DELETE "projects/${W_NS}%2Fapp/repository/branches/feature%2fx")"
expect A11h "a %2f-encoded branch name past a project path -> that project's bot" 0 FOUND "${W_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/:id/repository/files/lib%2F..%2Fa.ex")"
expect A11i "a %2F that hides a '..' segment past the project path -> BAD KEY" 2 "BAD KEY" "" "'..' segment"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/:id/repository/files/lib%2F%2e%2e%2Fa.ex")"
expect A11j "any escape but %2F past the project path still -> BAD KEY" 2 "BAD KEY" "" "past its project path"
R="$(fid_in "${PERS}" fid_resolve_glab_args api "projects/:id/issues")"
expect A12 "the :id placeholder uses origin" 0 FOUND "${P_BOT}" -
R="$(fid fid_resolve_url "https://gitlab.com/${W_NS}/../cjpoll/x.git")"
expect A13 "a '..' segment in a remote -> BAD KEY (the URL reaches another project)" 2 "BAD KEY" "" "'..' path segment"
R="$(fid fid_resolve_url "https://gitlab.com/${W_NS}/%2e%2e/cjpoll/x.git")"
expect A14 "an encoded dot in a remote -> BAD KEY" 2 "BAD KEY" "" "encoded dot"

echo
echo "--- every other word glab reads as a project must name the keyed namespace ---"
# glab acts on the project of a positional MR/issue URL, of mr create's
# -H/--head and --target-project, of -g/--group, and of a `repo` command's
# repository argument. Each is a key source; one that names another namespace
# than the bot was picked for is BAD KEY, never that bot acting there.
MRU="https://gitlab.com/${W_NS}/app/-/merge_requests/3"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr note "${MRU}" -m x)"
expect P1 "a positional work MR URL from a personal checkout -> BAD KEY, never the personal bot" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${WORK}" fid_resolve_glab_args mr note https://gitlab.com/cjpoll/custom/-/merge_requests/3 -m x)"
expect P2 "the reverse: a personal MR URL from a work checkout -> BAD KEY" 2 "BAD KEY" "" "names namespace 'cjpoll'"
R="$(fid_in "${WORK}" fid_resolve_glab_args mr note "${MRU}" -m x)"
expect P3 "an MR URL of the keyed namespace -> that bot" 0 FOUND "${W_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr note -R "${W_NS}/app" "${MRU}" -m x)"
expect P3b "-R and the MR URL agreeing -> that bot" 0 FOUND "${W_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr note 3 -m "see https://gitlab.com/${W_NS}/app/-/issues/1 for context")"
expect P4 "a URL inside a message word is text, not a key" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create -H "${W_NS}/app" --fill)"
expect P5 "mr create -H <work>/<p> from a personal checkout -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create --head="${W_NS}/app" --fill)"
expect P5b "--head=<work>/<p> -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create --head 1234 --fill)"
expect P5c "--head <numeric id> -> BAD KEY (it says nothing about its namespace)" 2 "BAD KEY" "" "numeric id"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create -fH "${W_NS}/app")"
expect P5d "-H combined with a short flag -> BAD KEY" 2 "BAD KEY" "" "combined with other short flags"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create "-tRefactor the Handler" -dSYNTH-1)"
expect P5e "an attached text value holding R/H (-tRefactor ..., -dSYNTH-1) is text, not a project flag" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr create --target-project "${W_NS}/app" --fill)"
expect P6 "mr create --target-project <work>/<p> -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list -g "${W_NS}")"
expect P7 "-g <work group> from a personal checkout -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list --group=cjpoll/sub)"
expect P7b "--group=<keyed namespace>/<sub> -> that bot" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args milestone list --group "${W_NS}%2Fsub")"
expect P7c "a URL-encoded --group of another namespace (milestone) -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list -fg "${W_NS}")"
expect P7d "-g combined with a short flag -> BAD KEY" 2 "BAD KEY" "" "combined with other short flags"
R="$(fid_in "${PERS}" fid_resolve_glab_args repo view "${W_NS}/app")"
expect P8 "repo view <work>/<p> -> BAD KEY" 2 "BAD KEY" "" "names namespace '${W_NS}'"
R="$(fid_in "${PERS}" fid_resolve_glab_args repo view cjpoll/custom)"
expect P8b "repo view <keyed namespace>/<p> -> that bot" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args repo fork my-project)"
expect P8c "repo fork <bare name> (glab reads it in the bot's own namespace) -> BAD KEY" 2 "BAD KEY" "" "bare name"
R="$(fid_in "${PERS}" fid_resolve_glab_args api -H "Accept: text/plain" "projects/:id/issues")"
expect P9 "api -H is a header, not a head project" 0 FOUND "${P_BOT}" -
R="$(fid_in "${PERS}" fid_resolve_glab_args mr list -R "https://u:s3cr3t@gitlab.com/someone-else/x")"
if [ "$(f_rc)" = 1 ] && [[ "$R" != *s3cr3t* ]]; then ok "A15. a -R URL's credentials never reach a refusal"
else bad "A15. -R credentials kept out" "got '${R}'"; fi
write_ov "[{\"host\":\"gitlab.com\",\"namespace\":\"${W_NS}\",\"bot\":\"${W_BOT}\",\"token_file\":\"${HOME}/.claude/personal-token\",\"refresh\":\"group_service_account\"}]"
R="$(fid fid_resolve_url https://gitlab.com/cjpoll/custom.git)"
expect A16 "two bots sharing one token file spelled ~/x and \$HOME/x -> COULD NOT LOOK" 3 "COULD NOT LOOK" "" "share the token file"
write_ov "[${W_ENTRY}]"
GH="$(mkrepo ghrepo https://github.com/someone/custom.git)"
R="$(fid_in "${GH}" fid_resolve_glab_args api user)"
expect G16 "a github.com origin -> NO ENTRY naming github.com" 1 "NO ENTRY" "" "github.com/someone"

echo
echo "--- ai/bin/forge-identity: the miss is visible before a landing ---"
CLI="${AI_DIR}/bin/forge-identity"
[ -n "${FORGE_IDENTITY_LIB_UNDER_TEST:-}" ] && CLI=""
if [ -n "${CLI}" ]; then
  HELP="$("${CLI}" --help 2>/dev/null)"; RC=$?
  [ "${RC}" = 0 ] && [[ "${HELP}" == *"Usage:"* ]] && ok "C1. --help on stdout, exit 0" || bad "C1. --help" "rc=${RC}"
  CR="${TMP}/check-root"; mkdir -p "${CR}"
  for spec in "p https://gitlab.com/cjpoll/custom.git" "w git@gitlab.com:${W_NS}/app.git" "gh https://github.com/x/y.git"; do
    git init -q "${CR}/${spec%% *}"; git -C "${CR}/${spec%% *}" remote add origin "${spec#* }"
  done
  mkdir -p "${CR}/not-a-repo"
  OUT="$("${CLI}" check --root "${CR}" 2>&1)"; RC=$?
  if [ "${RC}" = 0 ] && [[ "${OUT}" == *"OK   ${CR}/p -> ${P_BOT}"* ]] && [[ "${OUT}" == *"OK   ${CR}/w -> ${W_BOT}"* ]] \
    && [[ "${OUT}" != *"${CR}/gh"* ]] && [[ "${OUT}" == *"3 checkout(s)"*"2 with an origin"*"2 resolve to a bot, 0 do not"* ]]; then
    ok "C2. check: each GitLab checkout and its bot; a github.com checkout is not a candidate; counts printed"
  else bad "C2. check, all resolve" "rc=${RC} out='${OUT}'"; fi
  for spec in "u https://gitlab.com/someone-else/app.git" "a git@gitlab.com-work:${W_NS}/app.git"; do
    git init -q "${CR}/${spec%% *}"; git -C "${CR}/${spec%% *}" remote add origin "${spec#* }"
  done
  OUT="$("${CLI}" check --root "${CR}" 2>&1)"; RC=$?
  if [ "${RC}" = 1 ] && [[ "${OUT}" == *"MISS ${CR}/u: NO ENTRY"* ]] && [[ "${OUT}" == *"MISS ${CR}/a: NO ENTRY"*"gitlab.com-work"* ]] \
    && [ "$(grep -c '     Fix: ' <<<"${OUT}")" = 2 ] && [[ "${OUT}" == *"2 do not"* ]]; then
    ok "C3. check: an unmapped namespace and an aliased GitLab host are each a MISS with a Fix:, exit 1"
  else bad "C3. check, misses" "rc=${RC} out='${OUT}'"; fi
  OUT="$( (unset ATHENA_PRIVATE_ROOT; export HOME="${TMP}/no-overlay-home"; mkdir -p "${HOME}"; "${CLI}" check --root "${CR}") 2>&1)"; RC=$?
  if [ "${RC}" = 1 ] && [[ "${OUT}" == *"MISS ${CR}/w: NO ENTRY"*"ABSENT"* ]]; then
    ok "C4. check on a machine with no overlay: the work checkout is a MISS that says the overlay is absent"
  else bad "C4. check, overlay absent" "rc=${RC} out='${OUT}'"; fi
  EMPTY="${TMP}/empty-root"; mkdir -p "${EMPTY}"
  OUT="$("${CLI}" check --root "${EMPTY}" 2>&1)"; RC=$?
  [ "${RC}" = 0 ] && [[ "${OUT}" == *"nothing to resolve"* ]] && [[ "${OUT}" == *"0 checkout(s)"* ]] \
    && ok "C5. check with no candidate says so, with its counts (an empty result is never silent)" || bad "C5. empty root" "rc=${RC} out='${OUT}'"
  OUT="$(ATHENA_FORGE_IDENTITIES_FILE="${TMP}/no-such-map.json" "${CLI}" check --root "${CR}" 2>&1)"; RC=$?
  [ "${RC}" = 3 ] && [[ "${OUT}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" == *"Fix:"* ]] \
    && ok "C6. an unreadable map -> exit 3 COULD NOT LOOK, never a clean pass" || bad "C6. unreadable map" "rc=${RC} out='${OUT}'"
  OUT="$("${CLI}" resolve https://gitlab.com/cjpoll/custom.git 2>&1)"; RC=$?
  [ "${RC}" = 0 ] && [[ "${OUT}" == "OK gitlab.com/cjpoll -> ${P_BOT} "* ]] && ok "C7. resolve <url> prints the bot" || bad "C7. resolve" "rc=${RC} out='${OUT}'"
  OUT="$("${CLI}" resolve https://gitlab.com/CJPoll/custom.git 2>&1)"; RC=$?
  [ "${RC}" = 1 ] && [[ "${OUT}" == *"differs only in case"* ]] && [[ "${OUT}" == *"Fix:"* ]] && ok "C8. resolve of a wrong-case key -> exit 1 with Fix:" || bad "C8. resolve miss" "rc=${RC} out='${OUT}'"
  OUT="$("${CLI}" bogus 2>&1)"; RC=$?
  [ "${RC}" = 2 ] && [[ "${OUT}" == *"Fix:"* ]] && ok "C9. an unknown subcommand -> usage exit 2 with Fix:" || bad "C9. usage" "rc=${RC} out='${OUT}'"
fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
