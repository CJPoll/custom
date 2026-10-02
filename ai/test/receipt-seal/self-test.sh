#!/usr/bin/env bash
# self-test.sh -- ai/bin/receipt-seal and ai/lib/receipt_seal.rb (DND-1814).
# Discovered by harness-gate (every committed self-test.sh runs).
#
# Every case uses a temp ATHENA_SECRETS_ROOT, so the machine's real
# receipt-seal key is never read, minted or rotated. The landed-history cases
# run a fixture copy of the tool whose origin/main IS the copied tree
# (ai/test/lib/landed-fixture.bash), so they never depend on what the real
# origin/main holds. Functional only (DND-1222): no sleeps, no timing, no load.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
SEAL="${ROOT}/ai/bin/receipt-seal"
# shellcheck source=../lib/landed-fixture.bash
. "${ROOT}/ai/test/lib/landed-fixture.bash"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "receipt-seal self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${SEAL}" ] || { echo "receipt-seal self-test: FAIL -- ${SEAL} missing or not executable"; echo "  Fix: chmod +x ai/bin/receipt-seal"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
KEY="${ATHENA_SECRETS_ROOT}/harness/receipt-seal-key"
HEAD_A="$(printf 'a%.0s' $(seq 40))"

# A plain receipt body, as integration-gate's jq writes one.
new_receipt() { printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s"}\n' "${HEAD_A}" "${HEAD_A}" >"$1"; }
# Edit one JSON field in place, the way a hand-edit would (no reseal).
EDIT_RB="${TMP}/edit.rb"
printf '%s\n' 'require "json"' 'f, k, v = ARGV' 'b = JSON.parse(File.read(f))' 'b[k] = v' 'File.write(f, JSON.generate(b))' >"${EDIT_RB}"

echo "== help and usage"
out="$("${SEAL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && has "h1 --help exits 0 on stdout" "${out}" "receipt-seal verify" || bad "h1 --help rc=${rc}"
[ -e "${KEY}" ] && bad "h2 --help minted a key" || ok "h2 --help writes nothing"
"${SEAL}" verify "${TMP}/nofile" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 64 ] && ok "h3 a missing --kind is a usage error (64)" || bad "h3 expected 64, got ${rc}"
"${SEAL}" frobnicate --kind critic x >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 64 ] && ok "h4 an unknown command is a usage error (64)" || bad "h4 expected 64, got ${rc}"

echo "== seal and verify"
R="${TMP}/r.json"; new_receipt "${R}"
err="$("${SEAL}" verify --kind integration "${R}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && has "s1 an UNSEALED receipt is UNVERIFIED (exit 1)" "${err}" "UNSEALED" || bad "s1 expected 1, got ${rc}" "${err}"
has "s1 the refusal carries Fix:" "${err}" "Fix:"
[ -e "${KEY}" ] && bad "s1 verify minted a key (only a sealing writer may)" || ok "s1 verify never mints a key"
"${SEAL}" seal --kind integration "${R}"; rc=$?
[ "${rc}" -eq 0 ] && ok "s2 seal exits 0" || bad "s2 seal rc=${rc}"
[ "$(stat -c %a "${KEY}" 2>/dev/null)" = 600 ] && [ "$(stat -c %a "$(dirname "${KEY}")" 2>/dev/null)" = 700 ] \
  && ok "s2 the first seal mints the key 0600 in a 0700 directory" || bad "s2 key modes: $(stat -c '%a %n' "${KEY}" "$(dirname "${KEY}")" 2>&1)"
"${SEAL}" verify --kind integration "${R}"; rc=$?
[ "${rc}" -eq 0 ] && ok "s3 a sealed receipt VERIFIES (exit 0)" || bad "s3 expected 0, got ${rc}"
cp "${R}" "${TMP}/edited.json"; /usr/bin/ruby "${EDIT_RB}" "${TMP}/edited.json" verdict block
err="$("${SEAL}" verify --kind integration "${TMP}/edited.json" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && has "s4 a receipt edited after sealing is FORGED OR EDITED" "${err}" "FORGED OR EDITED" || bad "s4 expected 1, got ${rc}" "${err}"
err="$("${SEAL}" verify --kind critic "${R}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && has "s5 an integration seal never verifies as a critic receipt" "${err}" "producer" || bad "s5 expected 1, got ${rc}" "${err}"

echo "== the key"
chmod 644 "${KEY}"
err="$("${SEAL}" verify --kind integration "${R}" 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && has "k1 a group-readable key is COULD NOT LOOK (exit 3)" "${err}" "COULD NOT LOOK" || bad "k1 expected 3, got ${rc}" "${err}"
chmod 600 "${KEY}"
mv "${KEY}" "${KEY}.old"
err="$("${SEAL}" verify --kind integration "${R}" 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && has "k2 no key is COULD NOT LOOK, never a pass" "${err}" "no receipt-seal key" || bad "k2 expected 3, got ${rc}" "${err}"
new_receipt "${TMP}/r2.json"; "${SEAL}" seal --kind integration "${TMP}/r2.json"
err="$("${SEAL}" verify --kind integration "${R}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && has "k3 a receipt sealed under a rotated key is UNVERIFIED" "${err}" "ANOTHER KEY" || bad "k3 expected 1, got ${rc}" "${err}"
mv "${KEY}.old" "${KEY}"

echo "== the producer"
# A tree whose integration-receipt.sh differs from this checkout's, and that
# never landed anywhere: the shape of a branch's edited copy of the judge.
# Every file the integration producer names (KINDS, read from the library).
KINDS_RB="${TMP}/kinds.rb"
printf '%s\n' 'require ARGV[0]' 'puts ReceiptSeal::KINDS[ARGV[1]]' >"${KINDS_RB}"
mapfile -t INT_FILES < <(/usr/bin/ruby "${KINDS_RB}" "${ROOT}/ai/lib/receipt_seal.rb" integration)
[ "${#INT_FILES[@]}" -gt 0 ] || bad "p0 the integration producer list could not be read"
FAKE="${TMP}/fake"
for p in "${INT_FILES[@]}"; do mkdir -p "$(dirname "${FAKE}/${p}")"; cp -p "${ROOT}/${p}" "${FAKE}/${p}"; done
printf '\n# a branch edit\n' >>"${FAKE}/ai/lib/integration-receipt.sh"
new_receipt "${TMP}/fake.json"; "${FAKE}/ai/bin/receipt-seal" seal --kind integration "${TMP}/fake.json"
"${FAKE}/ai/bin/receipt-seal" verify --kind integration "${TMP}/fake.json"; rc=$?
[ "${rc}" -eq 0 ] && ok "p1 a copy verifies what it sealed itself (its own tree)" || bad "p1 expected 0, got ${rc}"
err="$("${SEAL}" verify --kind integration "${TMP}/fake.json" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && has "p2 a receipt from a judge that never landed is UNVERIFIED by this reader" "${err}" "NEVER LANDED" || bad "p2 expected 1, got ${rc}" "${err}"

# A landed fixture: what a reader in it sees for an OLDER landed producer.
FX="${TMP}/fx"
landed_fixture "${ROOT}" "${FX}" "${INT_FILES[@]}" || bad "p3 landed fixture"
new_receipt "${TMP}/old.json"; ( cd "${FX}" && ai/bin/receipt-seal seal --kind integration "${TMP}/old.json" )
printf '\n# landed later\n' >>"${FX}/ai/lib/integration-receipt.sh"
landed_fixture_land "${FX}" || bad "p3 land the later version"
( cd "${FX}" && ai/bin/receipt-seal verify --kind integration "${TMP}/old.json" ); rc=$?
[ "${rc}" -eq 0 ] && ok "p3 a receipt from an older LANDED version verifies (it is in origin/main's history)" || bad "p3 expected 0, got ${rc}"
printf '\n# never landed\n' >>"${FX}/ai/lib/integration-receipt.sh"
new_receipt "${TMP}/unlanded.json"; ( cd "${FX}" && ai/bin/receipt-seal seal --kind integration "${TMP}/unlanded.json" )
( cd "${FX}" && GIT_CONFIG_GLOBAL=/dev/null git checkout -q -- ai/lib/integration-receipt.sh )
err="$( cd "${FX}" && ai/bin/receipt-seal verify --kind integration "${TMP}/unlanded.json" 2>&1 )"; rc=$?
[ "${rc}" -eq 1 ] && has "p4 a receipt from an uncommitted edit is UNVERIFIED by the landed reader" "${err}" "NEVER LANDED" || bad "p4 expected 1, got ${rc}" "${err}"
( cd "${FX}" && GIT_CONFIG_GLOBAL=/dev/null git update-ref -d refs/remotes/origin/main )
err="$( cd "${FX}" && ai/bin/receipt-seal verify --kind integration "${TMP}/old.json" 2>&1 )"; rc=$?
[ "${rc}" -eq 3 ] && has "p5 a landed history that cannot be read is COULD NOT LOOK" "${err}" "does not resolve" || bad "p5 expected 3, got ${rc}" "${err}"

# A reader that is not a checkout (the landed temp tree integration-gate
# re-execs from) asks the CURRENT repo what landed. Run from a repo that is
# not the harness, that search cannot answer: COULD NOT LOOK, never "a judge
# that never landed" (whose Fix, re-judge, could not clear it).
READER="${TMP}/reader"
for p in "${INT_FILES[@]}"; do mkdir -p "$(dirname "${READER}/${p}")"; cp -p "${ROOT}/${p}" "${READER}/${p}"; done
OTHER="${TMP}/other-repo"; mkdir -p "${OTHER}"
( cd "${OTHER}" && GIT_CONFIG_GLOBAL=/dev/null git init -q . && printf 'x\n' >x \
  && GIT_CONFIG_GLOBAL=/dev/null git -c user.name=t -c user.email=t@example.invalid add x \
  && GIT_CONFIG_GLOBAL=/dev/null git -c user.name=t -c user.email=t@example.invalid commit -qm x \
  && GIT_CONFIG_GLOBAL=/dev/null git update-ref refs/remotes/origin/main HEAD ) || bad "p6 build the unrelated repo"
err="$( cd "${OTHER}" && "${READER}/ai/bin/receipt-seal" verify --kind integration "${TMP}/fake.json" 2>&1 )"; rc=$?
[ "${rc}" -eq 3 ] && has "p6 a landed history searched in another repo is COULD NOT LOOK" "${err}" "no history on" || bad "p6 expected 3, got ${rc}" "${err}"

echo "== one read of the receipt (DND-1814)"
# ir_read_receipt must check the fields and the seal on ONE read of the file.
# A seal tool stub swaps a genuinely sealed receipt into the store just before
# it verifies, the shape of a file replaced between the two reads. The file
# whose fields were read is unsealed, so the answer must be UNVERIFIED.
TC="${TMP}/tc"; mkdir -p "${TC}/integration-receipts"
HB="$(printf 'b%.0s' $(seq 40))"
GOOD="${TMP}/good.json"
printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s"}\n' "${HB}" "${HB}" >"${GOOD}"
"${SEAL}" seal --kind integration "${GOOD}" || bad "t0 seal the good receipt"
STORE_F="${TC}/integration-receipts/${HB}.json"
printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s"}\n' "${HB}" "${HB}" >"${STORE_F}"
SWAP="${TMP}/swap-seal"
printf '#!/usr/bin/env bash\ncp -- %q %q\nexec %q "$@"\n' "${GOOD}" "${STORE_F}" "${SEAL}" >"${SWAP}"; chmod +x "${SWAP}"
out="$(
  # shellcheck source=../../lib/integration-receipt.sh
  . "${ROOT}/ai/lib/integration-receipt.sh"
  IR_SEAL="${SWAP}"
  if ir_read_receipt "${TC}" "${HB}" "${HB}"; then echo "rc=0"; else echo "rc=1 kind=${IR_KIND}"; fi
)"
has "t1 a receipt swapped between the field read and the seal check is UNVERIFIED" "${out}" "rc=1 kind=RECEIPT UNVERIFIED"

echo "== init-key (the per-machine installer, DND-1814)"
IK_ROOT="${TMP}/ik-secrets"
IK_KEY="${IK_ROOT}/harness/receipt-seal-key"
out="$(ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key --check 2>&1)"; rc=$?
[ "${rc}" -eq 2 ] && has "i1 --check with no key is NOT PROVISIONED (exit 2)" "${out}" "NOT PROVISIONED" || bad "i1 expected 2, got ${rc}" "${out}"
[ -e "${IK_KEY}" ] && bad "i1 --check minted a key" || ok "i1 --check mints nothing"
# A stale temp file at the minting process's own <key>.tmp.<pid> (left by a
# killed run whose pid was reused) must not block the mint.
STALE_ROOT="${TMP}/stale-secrets"
STALE_RB="${TMP}/stale.rb"
printf '%s\n' 'require ARGV[0]' 'path = ARGV[1]' 'require "fileutils"' \
  'FileUtils.mkdir_p(File.dirname(path), mode: 0o700)' 'File.write("#{path}.tmp.#{Process.pid}", "")' \
  'key, why = ReceiptSeal.ensure_key(path)' 'puts(key ? "minted" : "refused: #{why}")' >"${STALE_RB}"
out="$(/usr/bin/ruby "${STALE_RB}" "${ROOT}/ai/lib/receipt_seal.rb" "${STALE_ROOT}/harness/receipt-seal-key" 2>&1)"
has "i1b a stale <key>.tmp.<pid> does not block the first mint" "${out}" "minted"
out="$(ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && has "i2 init-key mints the key and reports it" "${out}" "key OK" || bad "i2 expected 0, got ${rc}" "${out}"
[ "$(stat -c %a "${IK_KEY}" 2>/dev/null)" = 600 ] && ok "i2 the minted key is 0600" || bad "i2 key mode $(stat -c %a "${IK_KEY}" 2>&1)"
VAL="$(cat "${IK_KEY}" 2>/dev/null)"
case "${out}" in *"${VAL}"*) bad "i3 init-key printed the key value" ;; *) ok "i3 init-key prints metadata only, never the value" ;; esac
out2="$(ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && [ "$(cat "${IK_KEY}")" = "${VAL}" ] && ok "i4 init-key is idempotent: an existing key is kept" || bad "i4 rc=${rc} or the key changed" "${out2}"
ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key --check >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 0 ] && ok "i5 --check on a safe key exits 0" || bad "i5 expected 0, got ${rc}"
chmod 644 "${IK_KEY}"
out="$(ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key --check 2>&1)"; rc=$?
[ "${rc}" -eq 3 ] && has "i6 --check on an unsafe key exits 3 with Fix:" "${out}" "Fix:" || bad "i6 expected 3, got ${rc}" "${out}"
ATHENA_SECRETS_ROOT="${IK_ROOT}" "${SEAL}" init-key >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 1 ] && ok "i7 init-key refuses an unsafe key (exit 1), never rewrites it" || bad "i7 expected 1, got ${rc}"
"${SEAL}" init-key --bogus >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 64 ] && ok "i8 an unknown init-key flag is a usage error (64)" || bad "i8 expected 64, got ${rc}"

echo "== the integration producer is the gate's judge set"
# KINDS["integration"] must equal integration-gate's IG_JUDGE_PATHS, so a
# receipt written while any judge file was a branch edit never verifies.
LIST_RB="${TMP}/list.rb"
printf '%s\n' 'require ARGV[0]' 'puts ReceiptSeal::KINDS["integration"].sort' >"${LIST_RB}"
kinds="$(/usr/bin/ruby "${LIST_RB}" "${ROOT}/ai/lib/receipt_seal.rb")"
GATE_F="${ROOT}/ai/skills/athena:merge-boarding/scripts/integration-gate"
self_rel="$(sed -n 's/^IG_SELF_REL="\(.*\)"$/\1/p' "${GATE_F}")"
judges="$(sed -n '/^IG_JUDGE_PATHS=(/,/)/p' "${GATE_F}" | tr -d '()' | sed 's/IG_JUDGE_PATHS=//' | tr ' ' '\n' \
  | sed '/^$/d' | sed "s|^\"\$IG_SELF_REL\"\$|${self_rel}|" | sort)"
if [ -n "${kinds}" ] && [ -n "${self_rel}" ] && [ "${kinds}" = "${judges}" ]; then
  ok "j1 KINDS[integration] equals IG_JUDGE_PATHS ($(printf '%s\n' "${kinds}" | wc -l) files)"
else
  bad "j1 KINDS[integration] differs from IG_JUDGE_PATHS" "kinds=[$(echo ${kinds})] judges=[$(echo ${judges})]"
fi

echo
echo "receipt-seal self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { echo "Fix: read each FAIL line above; a seal that verifies what it should refuse is the DND-1814 defect."; exit 1; }
exit 0
