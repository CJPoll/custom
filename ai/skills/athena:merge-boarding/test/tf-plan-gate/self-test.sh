#!/usr/bin/env bash
# Self-test for ai/skills/athena:merge-boarding/scripts/tf-plan-gate.
# Hermetic: plan-JSON fixtures in a temp dir, in the shape
# `terraform show -json` emits (format_version + resource_changes). No
# terraform, no network, no AWS.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../../scripts" && pwd)/tf-plan-gate"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# rc TYPE ACTIONS BEFORE AFTER [AFTER_UNKNOWN] -> one resource_changes entry
rc() {
  printf '{"address":"%s.x","mode":"managed","type":"%s","name":"x","change":{"actions":%s,"before":%s,"after":%s,"after_unknown":%s}}' \
    "$1" "$1" "$2" "$3" "$4" "${5-{\}}"
}
plan() { local f="${TMP}/$1.json"; shift; local IFS=,; printf '{"format_version":"1.2","resource_changes":[%s]}' "$*" > "$f"; echo "$f"; }

# case NAME WANT_RC PLANFILE [extra args]
check() {
  local name="$1" want="$2"; shift 2
  local out rc; out="$("${TOOL}" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "${name} (exit ${rc})"; else bad "${name}: expected ${want}, got ${rc}" "$out"; fi
}

check rds-destroy          4 --plan "$(plan a "$(rc aws_db_instance '["delete"]' '{"instance_class":"db.t4g.micro"}' null)")"
check rds-replace          4 --plan "$(plan b "$(rc aws_db_instance '["delete","create"]' '{}' '{}')")"
check kms-key-replace      4 --plan "$(plan c "$(rc aws_kms_key '["create","delete"]' '{}' '{}')")"
check unknown-type-destroy 4 --plan "$(plan d "$(rc aws_something_new '["delete"]' '{}' null)")"
check sg-replace-clear     0 --plan "$(plan e "$(rc aws_security_group '["delete","create"]' '{}' '{}')")"
check new-instance-cost    4 --plan "$(plan f "$(rc aws_instance '["create"]' null '{"instance_type":"t4g.small"}')")"
check new-kms-key-cost     4 --plan "$(plan g "$(rc aws_kms_key '["create"]' null '{}')")"
check new-iam-free         0 --plan "$(plan h "$(rc aws_iam_role_policy '["create"]' null '{"policy":"{}"}')")"
check resize-instance      4 --plan "$(plan i "$(rc aws_instance '["update"]' '{"instance_type":"t4g.small"}' '{"instance_type":"t4g.medium"}')")"
check downsize-also-holds  4 --plan "$(plan j "$(rc aws_db_instance '["update"]' '{"instance_class":"db.t4g.medium"}' '{"instance_class":"db.t4g.micro"}')")"
check nested-volume-size   4 --plan "$(plan k "$(rc aws_instance '["update"]' '{"root_block_device":[{"volume_size":20}]}' '{"root_block_device":[{"volume_size":40}]}')")"
check size-unknown         4 --plan "$(plan l "$(rc aws_instance '["update"]' '{"instance_type":"a"}' '{}' '{"instance_type":true}')")"
check ssm-tier-advanced    4 --plan "$(plan m "$(rc aws_ssm_parameter '["update"]' '{"tier":"Standard"}' '{"tier":"Advanced"}')")"
check secret-value-update  0 --plan "$(plan n "$(rc aws_ssm_parameter '["update"]' '{"value":"a","tier":"Standard"}' '{"value":"b","tier":"Standard"}')")"
check secret-version-new   0 --plan "$(plan o "$(rc aws_secretsmanager_secret_version '["create"]' null '{}')")"
check random-pw-replace    0 --plan "$(plan p "$(rc random_password '["delete","create"]' '{}' '{}')")"
check tag-update-clear     0 --plan "$(plan q "$(rc aws_instance '["update"]' '{"tags":{"a":"1"}}' '{"tags":{"a":"2"}}')")"
check no-op-and-read       0 --plan "$(plan r "$(rc aws_db_instance '["no-op"]' '{}' '{}')" "$(rc aws_db_instance '["read"]' '{}' '{}')")"
check empty-plan-clear     0 --plan "$(plan s)"
check data-mode-ignored    0 --plan "$(printf '{"format_version":"1.2","resource_changes":[{"address":"data.x.y","mode":"data","type":"aws_db_instance","change":{"actions":["delete"]}}]}' > "${TMP}/t.json"; echo "${TMP}/t.json")"

# --control subtracts a change the base plan has identically.
drift="$(rc aws_instance '["update"]' '{"instance_type":"a"}' '{"instance_type":"b"}')"
check control-subtracts    0 --plan "$(plan u "$drift")" --control "$(plan v "$drift")"
check control-keeps-new    4 --plan "$(plan w "$drift" "$(rc aws_db_instance '["delete"]' '{}' null)")" --control "$(plan x "$drift")"

# Fail closed: not a plan, not JSON, missing file, no --plan.
printf '{"version":4,"resources":[]}' > "${TMP}/state.json"
check state-file-not-plan  3 --plan "${TMP}/state.json"
printf 'Plan: 1 to add' > "${TMP}/human.txt"
check human-plan-text      3 --plan "${TMP}/human.txt"
# Terraform 1.14 writes a plan file even when planning FAILS (prevent_destroy
# refusing a destroy): errored:true, the refused resource absent. Measured
# live 2026-09-27; it read CLEAR before this case existed.
printf '{"format_version":"1.2","errored":true,"complete":true,"resource_changes":[%s]}' \
  "$(rc terraform_data '["update"]' '{}' '{}')" > "${TMP}/errored.json"
check errored-plan         3 --plan "${TMP}/errored.json"
printf '{"format_version":"1.2","errored":false,"complete":false,"resource_changes":[]}' > "${TMP}/partial.json"
check incomplete-plan      3 --plan "${TMP}/partial.json"
check missing-file         2 --plan "${TMP}/nope.json"
check no-plan-flag         2

out="$("${TOOL}" --help)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Usage:' <<<"$out"; then ok "--help"; else bad "--help" "$out"; fi
out="$("${TOOL}" --plan "${TMP}/a.json" 2>&1)"
if grep -q '^Fix:' <<<"$out"; then ok "HOLD carries Fix:"; else bad "HOLD carries Fix:" "$out"; fi

echo "tf-plan-gate self-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
