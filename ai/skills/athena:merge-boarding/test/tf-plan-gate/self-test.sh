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
# planc NAME CONFIG_FIELD ONE_RC [EXTRA_TOP_LEVEL_FIELDS]: a plan with a configuration block
planc() { local f="${TMP}/$1.json"; printf '{"format_version":"1.2",%s,"resource_changes":[%s]%s}' "$2" "$3" "${4-}" > "$f"; echo "$f"; }

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
# A free-listed type is free only at its free sizing: a new Advanced-tier SSM
# parameter is billed. Checked online and offline with no control counterpart.
check new-ssm-advanced     4 --plan "$(plan ea "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"x","tier":"Advanced"}')")"
check new-ssm-standard     0 --plan "$(plan eb "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"x","tier":"Standard"}')")"
# An unset tier is unknown on every new SSM parameter: after_unknown below is
# verbatim from a real plan (AWS provider 5.100.0, terraform 1.14.3,
# 2026-09-27). It takes the provider/account default, a size the diff did not
# choose, so it does not hold; the secrets create ships.
SSM_REAL_UNK='{"arn":true,"data_type":true,"has_value_wo":true,"id":true,"insecure_value":true,"key_id":true,"tags_all":true,"tier":true,"version":true}'
check new-ssm-tier-default 0 --plan "$(plan ec "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","type":"SecureString","value":"x"}' "$SSM_REAL_UNK")")"
check offline-new-ssm-advanced 4 --plan "$(plan ed "$(rc aws_ssm_parameter '["create"]' null '{"name":"/b","value":"x","tier":"Advanced"}')")" \
                             --control "$(plan ee)"
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
# Online, an update of a value-holding type can do what its delete does:
# suspending versioning is a destroy of the version history's protection.
# Only a value/tags/description change passes, online as offline.
check s3-versioning-suspend 4 --plan "$(plan ca "$(rc aws_s3_bucket_versioning '["update"]' '{"versioning_configuration":[{"status":"Enabled"}]}' '{"versioning_configuration":[{"status":"Suspended"}]}')")"
check ghsecret-repo-update 4 --plan "$(plan cb "$(rc github_actions_secret '["update"]' '{"repository":"a","plaintext_value":"x"}' '{"repository":"b","plaintext_value":"x"}')")"
check ghsecret-value-update 0 --plan "$(plan cc "$(rc github_actions_secret '["update"]' '{"repository":"a","plaintext_value":"x"}' '{"repository":"a","plaintext_value":"y"}')")"
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

# --control is the offline method only. An offline plan has no state, so every
# action is `create`, and a create the base plan has identically is an
# existing resource, not the diff's. A plan with state (any update or delete,
# in either plan) is judged whole, drift included: merging applies the whole
# plan. --control on one is refused (exit 2), never read as CLEAR.
inst="$(rc aws_instance '["create"]' null '{"instance_type":"t"}')"
check control-subtracts-create 0 --plan "$(plan u "$inst")" --control "$(plan v "$inst")"
check control-keeps-new    4 --plan "$(plan w "$inst" "$(rc aws_db_instance '["create"]' null '{}')")" --control "$(plan x "$inst")"
drift="$(rc aws_instance '["update"]' '{"instance_type":"a"}' '{"instance_type":"b"}')"
check control-online-sizing-drift 2 --plan "$(plan ua "$drift")" --control "$(plan va "$drift")"
susp="$(rc aws_s3_bucket_versioning '["update"]' '{"versioning_configuration":[{"status":"Enabled"}]}' '{"versioning_configuration":[{"status":"Suspended"}]}')"
check control-online-versioning-drift 2 --plan "$(plan ub "$susp")" --control "$(plan vb "$susp")"
gone="$(rc aws_db_instance '["delete"]' '{}' null)"
check control-online-destroy 2 --plan "$(plan y "$gone")" --control "$(plan z "$gone")"
check control-online-in-control 2 --plan "$(plan uc "$inst")" --control "$(plan vc "$drift")"
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
# Real plans mark computed attributes unknown: a create's id/arn/version, an
# update's recomputed version or updated_at. Those are not config and must
# not hold the secrets updates the owner said ship. An unknown attribute that
# IS config (name) still holds, and so does one unknown only in the change.
SSM_CREATE_UNK='{"id":true,"arn":true,"version":true}'
check offline-value-computed 0 --plan "$(plan da "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"b"}' "$SSM_CREATE_UNK")")" \
                             --control "$(plan db "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"a"}' "$SSM_CREATE_UNK")")"
# version_stages is optional+computed: unset in config, unknown in both.
SVC='"configuration":{"root_module":{"resources":[{"address":"aws_secretsmanager_secret_version.x","expressions":{"secret_id":{"constant_value":"s"},"secret_string":{"constant_value":"v"}}}]}}'
check offline-secretver-computed 0 --plan "$(planc dc "$SVC" "$(rc aws_secretsmanager_secret_version '["create"]' null '{"secret_id":"s","secret_string":"b"}' '{"id":true,"arn":true,"version_id":true,"version_stages":true}')")" \
                             --control "$(planc dd "$SVC" "$(rc aws_secretsmanager_secret_version '["create"]' null '{"secret_id":"s","secret_string":"a"}' '{"id":true,"arn":true,"version_id":true,"version_stages":true}')")"
# Offline, "unknown in both plans" is not "unchanged": every reference to
# another resource is unknown in both. Set aside only when the configuration
# expression is provably the same (shapes as in a real `terraform show -json`,
# AWS provider 5.100.0, 2026-09-27). With no configuration: holds (fail wide).
check offline-both-unknown-noconfig 4 --plan "$(plan de "$(rc aws_ssm_parameter '["create"]' null '{"value":"b"}' '{"id":true,"name":true}')")" \
                             --control "$(plan df "$(rc aws_ssm_parameter '["create"]' null '{"value":"a"}' '{"id":true,"name":true}')")"
SV_UNK='{"arn":true,"has_secret_string_wo":true,"id":true,"secret_id":true,"version_id":true,"version_stages":true}'
sv() { rc aws_secretsmanager_secret_version '["create"]' null "{\"secret_string\":\"$1\"}" "$SV_UNK"; }
# cfg REF: root-module config for aws_secretsmanager_secret_version.x with secret_id = REF
cfg() { printf '"configuration":{"root_module":{"resources":[{"address":"aws_secretsmanager_secret_version.x","expressions":{"secret_id":{"references":["%s"]},"secret_string":{"constant_value":"v"}}}]}}' "$1"; }
check offline-ref-same     0 --plan "$(planc ea "$(cfg aws_secretsmanager_secret.a.id)" "$(sv b)")" \
                             --control "$(planc eb "$(cfg aws_secretsmanager_secret.a.id)" "$(sv a)")"
check offline-ref-repointed 4 --plan "$(planc ec "$(cfg aws_secretsmanager_secret.b.id)" "$(sv b)")" \
                             --control "$(planc ed "$(cfg aws_secretsmanager_secret.a.id)" "$(sv a)")"
check offline-ref-local    4 --plan "$(planc ee "$(cfg local.sid)" "$(sv b)")" \
                             --control "$(planc ef "$(cfg local.sid)" "$(sv a)")"
check offline-ref-rootvar-same 0 --plan "$(planc eg "$(cfg var.sid)" "$(sv b)" ',"variables":{"sid":{"value":"s1"}}')" \
                             --control "$(planc eh "$(cfg var.sid)" "$(sv a)" ',"variables":{"sid":{"value":"s1"}}')"
check offline-ref-rootvar-changed 4 --plan "$(planc ei "$(cfg var.sid)" "$(sv b)" ',"variables":{"sid":{"value":"s2"}}')" \
                             --control "$(planc ej "$(cfg var.sid)" "$(sv a)" ',"variables":{"sid":{"value":"s1"}}')"
# Inside a module, var.sid resolves through the module call's expression.
mcfg() { printf '"configuration":{"root_module":{"module_calls":{"m":{"expressions":{"sid":{"references":["%s"]}},"module":{"resources":[{"address":"aws_secretsmanager_secret_version.x","expressions":{"secret_id":{"references":["var.sid"]}}}]}}}}}' "$1"; }
msv() { printf '{"address":"module.m.aws_secretsmanager_secret_version.x[0]","mode":"managed","type":"aws_secretsmanager_secret_version","name":"x","index":0,"change":{"actions":["create"],"before":null,"after":{"secret_string":"%s"},"after_unknown":%s}}' "$1" "$SV_UNK"; }
check offline-module-var-same 0 --plan "$(planc ek "$(mcfg aws_secretsmanager_secret.a.id)" "$(msv b)")" \
                             --control "$(planc el "$(mcfg aws_secretsmanager_secret.a.id)" "$(msv a)")"
check offline-module-var-repointed 4 --plan "$(planc em "$(mcfg aws_secretsmanager_secret.b.id)" "$(msv b)")" \
                             --control "$(planc en "$(mcfg aws_secretsmanager_secret.a.id)" "$(msv a)")"
check offline-name-unknown-realistic 4 --plan "$(plan dg "$(rc aws_ssm_parameter '["create"]' null '{"value":"x"}' '{"id":true,"arn":true,"version":true,"name":true}')")" \
                             --control "$(plan dh "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"x"}' "$SSM_CREATE_UNK")")"
check online-ssm-value-computed 0 --plan "$(plan di "$(rc aws_ssm_parameter '["update"]' '{"id":"/a","name":"/a","value":"a","version":3,"tier":"Standard"}' '{"id":"/a","name":"/a","value":"b","tier":"Standard"}' '{"version":true}')")"
check online-ghsecret-value-computed 0 --plan "$(plan dj "$(rc github_actions_secret '["update"]' '{"repository":"r","plaintext_value":"a","updated_at":"t1"}' '{"repository":"r","plaintext_value":"b"}' '{"updated_at":true}')")"
check online-ssm-name-unknown 4 --plan "$(plan dk "$(rc aws_ssm_parameter '["update"]' '{"name":"/a","value":"a"}' '{"value":"a"}' '{"name":true}')")"
# Offline sizing: an attribute unknown in BOTH creates is not the diff's only
# when its config is provably the same: unset in both (a provider default), or
# the same expression. One unknown only in the change always holds.
pcfg() { printf '"configuration":{"root_module":{"resources":[{"address":"aws_ssm_parameter.x","expressions":{"name":{"constant_value":"/a"}%s}}]}}' "${1-}"; }
check offline-size-unset-both 0 --plan "$(planc dl "$(pcfg)" "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"b"}' '{"id":true,"tier":true}')")" \
                             --control "$(planc dm "$(pcfg)" "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"a"}' '{"id":true,"tier":true}')")"
check offline-size-repointed 4 --plan "$(planc dp "$(pcfg ',"tier":{"references":["local.big"]}')" "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"b"}' '{"id":true,"tier":true}')")" \
                             --control "$(planc dq "$(pcfg)" "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"a"}' '{"id":true,"tier":true}')")"
check offline-size-unknown-noconfig 4 --plan "$(plan dr "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"b"}' '{"id":true,"tier":true}')")" \
                             --control "$(plan ds "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"a"}' '{"id":true,"tier":true}')")"
# A tag map is a label: a tag named `tier` is not a billed size.
check new-sg-tier-tag      0 --plan "$(plan dt "$(rc aws_security_group '["create"]' null '{"tags":{"tier":"web"}}')")"
check malformed-rc-element 3 --plan "$(printf '{"format_version":"1.2","resource_changes":["x"]}' > "${TMP}/mal.json"; echo "${TMP}/mal.json")"
check offline-size-unknown-change 4 --plan "$(plan dn "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"b"}' '{"id":true,"tier":true}')")" \
                             --control "$(plan do "$(rc aws_ssm_parameter '["create"]' null '{"name":"/a","value":"a","tier":"Standard"}' '{"id":true}')")"
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
