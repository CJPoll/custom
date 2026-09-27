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
# Free to create or update, but a destroy or replace loses the stored value
# (often set out-of-band with ignore_changes). The owner's carve-out is
# secrets UPDATES, not deletes.
check ssm-param-delete     4 --plan "$(plan ba "$(rc aws_ssm_parameter '["delete"]' '{}' null)")"
check ssm-param-replace    4 --plan "$(plan bb "$(rc aws_ssm_parameter '["delete","create"]' '{}' '{}')")"
check secret-version-delete 4 --plan "$(plan bc "$(rc aws_secretsmanager_secret_version '["delete"]' '{}' null)")"
check gh-secret-delete     4 --plan "$(plan bd "$(rc github_actions_secret '["delete"]' '{}' null)")"
check s3-versioning-delete 4 --plan "$(plan be "$(rc aws_s3_bucket_versioning '["delete"]' '{}' null)")"
check control-only-ssm     4 --plan "$(plan bf)" --control "$(plan bg "$(rc aws_ssm_parameter '["create"]' null '{}')")"
# An expiration policy deletes stored objects or images when it runs.
check s3-lifecycle-create  4 --plan "$(plan bh "$(rc aws_s3_bucket_lifecycle_configuration '["create"]' null '{}')")"
check ecr-lifecycle-update 4 --plan "$(plan bi "$(rc aws_ecr_lifecycle_policy '["update"]' '{"policy":"a"}' '{"policy":"b"}')")"
check ecr-lifecycle-delete 0 --plan "$(plan bj "$(rc aws_ecr_lifecycle_policy '["delete"]' '{}' null)")"
check random-pw-replace    0 --plan "$(plan p "$(rc random_password '["delete","create"]' '{}' '{}')")"
check tag-update-clear     0 --plan "$(plan q "$(rc aws_instance '["update"]' '{"tags":{"a":"1"}}' '{"tags":{"a":"2"}}')")"
check no-op-and-read       0 --plan "$(plan r "$(rc aws_db_instance '["no-op"]' '{}' '{}')" "$(rc aws_db_instance '["read"]' '{}' '{}')")"
check empty-plan-clear     0 --plan "$(plan s)"
check data-mode-ignored    0 --plan "$(printf '{"format_version":"1.2","resource_changes":[{"address":"data.x.y","mode":"data","type":"aws_db_instance","change":{"actions":["delete"]}}]}' > "${TMP}/t.json"; echo "${TMP}/t.json")"

# --control subtracts a change the base plan has identically.
drift="$(rc aws_instance '["update"]' '{"instance_type":"a"}' '{"instance_type":"b"}')"
check control-subtracts    0 --plan "$(plan u "$drift")" --control "$(plan v "$drift")"
check control-keeps-new    4 --plan "$(plan w "$drift" "$(rc aws_db_instance '["delete"]' '{}' null)")" --control "$(plan x "$drift")"
# --control never subtracts a destroy: merging applies the whole plan, so a
# delete the base plan also has (drift) still happens.
gone="$(rc aws_db_instance '["delete"]' '{}' null)"
check control-keeps-destroy 4 --plan "$(plan y "$gone")" --control "$(plan z "$gone")"
# Offline plans have no state, so every resource reads `create`. A change
# that deletes the resource block leaves it only in the control: a destroy.
rds_new="$(rc aws_db_instance '["create"]' null '{}')"
check control-only-destroy 4 --plan "$(plan aa)" --control "$(plan ab "$rds_new")"
check control-only-free    0 --plan "$(plan ac)" --control "$(plan ad "$(rc aws_iam_role '["create"]' null '{}')")"
# Offline, a resize reads as create-vs-create: compare the sizing attributes
# against the control's create at the same address.
check offline-ssm-tier     4 --plan "$(plan af "$(rc aws_ssm_parameter '["create"]' null '{"tier":"Advanced"}')")" \
                             --control "$(plan ag "$(rc aws_ssm_parameter '["create"]' null '{"tier":"Standard"}')")"
check offline-value-clear  0 --plan "$(plan ah "$(rc aws_ssm_parameter '["create"]' null '{"value":"b","tier":"Standard"}')")" \
                             --control "$(plan ai "$(rc aws_ssm_parameter '["create"]' null '{"value":"a","tier":"Standard"}')")"
# Offline, a value-holding type's update and its force-new replace both read
# create-vs-create. Only a value/tags/description change is known in place;
# any other differing attribute may force a replace, so it holds.
check offline-ssm-rename   4 --plan "$(plan aj "$(rc aws_ssm_parameter '["create"]' null '{"name":"/b","value":"x"}')")" \
                             --control "$(plan ak "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"x"}')")"
check offline-ghsecret-repo 4 --plan "$(plan al "$(rc github_actions_secret '["create"]' null '{"repository":"b"}')")" \
                             --control "$(plan am "$(rc github_actions_secret '["create"]' null '{"repository":"a"}')")"
check offline-ssm-name-unknown 4 --plan "$(plan an "$(rc aws_ssm_parameter '["create"]' null '{"value":"x"}' '{"name":true}')")" \
                             --control "$(plan ao "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"x"}')")"
check offline-secret-tags  0 --plan "$(plan ap "$(rc aws_secretsmanager_secret_version '["create"]' null '{"secret_id":"s","secret_string":"b","tags":{"a":"2"}}')")" \
                             --control "$(plan aq "$(rc aws_secretsmanager_secret_version '["create"]' null '{"secret_id":"s","secret_string":"a","tags":{"a":"1"}}')")"
# A `moved` block renames the address; the old one is not a destroy.
printf '{"format_version":"1.2","resource_changes":[{"address":"aws_db_instance.y","previous_address":"aws_db_instance.x","mode":"managed","type":"aws_db_instance","name":"y","change":{"actions":["no-op"],"before":{},"after":{},"after_unknown":{}}}]}' > "${TMP}/moved.json"
check control-moved-clear  0 --plan "${TMP}/moved.json" --control "$(plan ae "$(rc aws_db_instance '["no-op"]' '{}' '{}')")"

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
