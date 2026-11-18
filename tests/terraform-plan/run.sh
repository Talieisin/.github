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

if ! command -v shellcheck > /dev/null 2>&1; then
  bad "shellcheck is not installed: the extracted scripts were not checked"
elif shellcheck -S warning "$work"/*.sh; then ok; else bad "shellcheck of the extracted scripts"; fi

# --- Signed commits of George's -------------------------------------------------
commits_prog=$(awk '
  /others=\$\(jq -ec --argjson p "\$PLAN_PERSON_ID" \x27/ { sub(/.*--argjson p "\$PLAN_PERSON_ID" \x27/, ""); sub(/\x27 <<<"\$commits".*/, ""); print }' <<<"$gate")
[ -n "$commits_prog" ] || { echo "could not extract the commit check" >&2; exit 2; }
cm() { # author_id author_type committer_id committer_type committer_login verified
  jq -cn --argjson ai "$1" --arg at "$2" --argjson ci "$3" --arg ct "$4" --arg cl "$5" --argjson v "$6" \
    '{sha: "0123456789abcdef0123456789abcdef01234567", author: {id: $ai, type: $at, login: "a"}, committer: {id: $ci, type: $ct, login: $cl}, commit: {verification: {verified: $v}}}'
}
others() { jq -c --argjson p 146720324 "$commits_prog" <<<"$1" | jq 'length'; }
expect "commits: George's, signed" 0 "$(others "[$(cm 146720324 User 146720324 User g true)]")"
expect "commits: unsigned" 1 "$(others "[$(cm 146720324 User 146720324 User g false)]")"
expect "commits: another person's" 1 "$(others "[$(cm 42 User 42 User x true)]")"
expect "commits: another author" 1 "$(others "[$(cm 42 User 146720324 User g true)]")"
expect "commits: web-flow" 1 "$(others "[$(cm 146720324 User 19864447 User web-flow true)]")"
expect "commits: a bot" 1 "$(others "[$(cm 146720324 User 99 Bot b true)]")"
expect "commits: unlinked author" 1 "$(others "[$(jq -cn '{sha: "x", author: null, committer: {id: 146720324, type: "User", login: "g"}, commit: {verification: {verified: true}}}')]")"

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
  {"address":"azurerm_storage_account.c[271828]","mode":"managed","change":{"actions":["delete"],"before":{"name":"c"},"after":null}},
  {"address":"data.x.y","mode":"data","change":{"actions":["read"]}}],
  "resource_drift":[{"address":"azurerm_role_assignment.r[\"DRIFTSECRET\"]","mode":"managed","change":{"actions":["update"],"before":{"x":1},"after":{"x":2}}}],
  "output_changes":{"o":{"actions":["update"],"before":"OLDOUT","after":"NEWOUT"}}}'
out=$("$work/plan-summary.sh" platform <<<"$plan")
if grep -E 'TOPSECRET|NEWSECRET|KEYSECRET|SPLITSECRET|DRIFTSECRET|OLDOUT|NEWOUT|271828' <<<"$out" > /dev/null; then bad "summary: a value or key leaks"; echo "$out"; else ok; fi
expect "summary: heading" "#### platform tier" "$out"
for want in 'Plan: 2 to add, 1 to change, 1 to destroy.' '| update | `azurerm_key_vault_secret.s` | value |' \
            '| create | `azurerm_storage_account.a[…]` |' '| create | `azurerm_storage_account.b[…]` |' \
            '| delete | `azurerm_storage_account.c[…]` |' '| update | `azurerm_role_assignment.r[…]` | x |' 'Outputs: update `o`'; do
  if grep -F -- "$want" <<<"$out" > /dev/null; then ok; else bad "summary: missing '$want'"; fi
done
rc=0; "$work/plan-summary.sh" platform <<<'not json' > /dev/null 2>&1 || rc=$?
expect "summary: not a plan" 3 "$rc"
rc=0; "$work/plan-summary.sh" identity <<<"$plan" > /dev/null 2>&1 || rc=$?
expect "summary: unknown tier" 2 "$rc"


# --- Tier rules ---------------------------------------------------------------
repo="$work/repo"
tier="$repo/infrastructure/terraform/compute"
envdir="$repo/infrastructure/terraform/environments"
mkdir -p "$tier/files" "$envdir"
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
printf 'terraform {\n  backend "azurerm" {}\n}\n' > "$tier/backend.tf"
cat > "$tier/main.tf" <<'TF'
data "terraform_remote_state" "platform" {
  backend = "azurerm"
  config = {
    key              = "caersid/platform-production.tfstate"
    use_azuread_auth = true
  }
}
TF
cat > "$tier/storage.tf" <<'TF'
# Static site storage.
resource "azurerm_storage_account" "this" {
  name     = "st"
  provider = azurerm
}

resource "azurerm_storage_blob" "serve" {
  name   = "serve.json"
  source = "${path.module}/files/serve.json"
}
TF
printf 'variable "subscription_id" {\n  type = string\n}\n' > "$tier/variables.tf"
printf '{}\n' > "$tier/files/serve.json"
printf 'provider "registry.terraform.io/hashicorp/azurerm" {\n  version = "5.12.0"\n}\n' > "$tier/.terraform.lock.hcl"
printf 'subscription_id = "x"\n' > "$envdir/compute-production.tfvars"
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
append() { printf '%b' "$2" >> "$tier/$1"; }

# Planned: ordinary changes, including the false positives of a keyword scan.
rules "unchanged" 0 "ok:"
append storage.tf '\nresource "azurerm_storage_container" "c" {\n  name = "c"\n}\n'
rules "a new resource" 0 "ok:"
append storage.tf '\nresource "azurerm_role_assignment" "r" {\n  scope              = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st"\n  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/abc"\n}\n'
rules "a resource ID with /providers/" 0 "ok:"
append storage.tf '\nresource "azurerm_storage_blob" "b" {\n  source = "${path.module}/files/b.json"\n}\n'
rules "path.module" 0 "ok:"
append storage.tf '\n# The backend and the provider are set in versions.tf; no module here.\n// terraform { } lives elsewhere\n'
rules "comment lines naming keywords" 0 "ok:"
append storage.tf '\noutput "e" {\n  value = azurerm_storage_account.this.primary_web_endpoint\n}\n'
rules "an endpoint attribute" 0 "ok:"
awk '/provider = azurerm/ { held = $0; next } { print } END { print held }' "$tier/storage.tf" > "$work/s" && mv "$work/s" "$tier/storage.tf"
rules "a risky line moved within its file" 0 "ok:"

# Not planned: frozen files.
append versions.tf '\n# a comment\n'
rules "versions.tf changed at all" 3 "versions.tf differs"
awk '{ print } /^provider "azurerm"/ { print "  metadata_host = \"evil.example\"" }' "$tier/versions.tf" > "$work/v" && mv "$work/v" "$tier/versions.tf"
rules "metadata_host in the provider block" 3 "versions.tf differs"
mv "$tier/versions.tf" "$tier/providers.tf"
rules "versions.tf renamed" 3 "versions.tf differs"
rm "$tier/backend.tf"
rules "backend.tf removed" 3 "backend.tf differs"
sed -i.bak 's/use_azuread_auth = true/use_azuread_auth = true\n    ${"oidc"}_request_url = "https:\/\/evil.example"/' "$tier/main.tf" && rm "$tier/main.tf.bak"
rules "a built key in the remote-state config" 3 "main.tf mentions terraform_remote_state"
append main.tf '\nlocals {\n  x = 1\n}\n'
rules "any change to the remote-state file" 3 "main.tf mentions terraform_remote_state"
append storage.tf '\ndata "terraform_remote_state" "x" {\n  backend = "http"\n  config  = merge({}, jsondecode(var.c))\n}\n'
rules "remote state in another file" 3 "storage.tf mentions terraform_remote_state"
printf 'subscription_id = "y"\n' > "$envdir/compute-production.tfvars"
rules "tfvars changed" 3 "the tier's tfvars file differs"
printf 'c = "{}"\n' > "$tier/extra.auto.tfvars"
rules "an auto.tfvars file" 3 "extra.auto.tfvars differs"
printf 'c = "{}"\n' > "$tier/terraform.tfvars"
rules "a terraform.tfvars file" 3 "terraform.tfvars differs"
append .terraform.lock.hcl '\n'
rules "lock file changed" 3 "the tier's .terraform.lock.hcl differs"

# Not planned: modules, links, special files, risky lines.
append storage.tf '\nmodule x {\n  source = "./m"\n}\n'
rules "a bare-label module" 3 "storage.tf adds"
append storage.tf '\nmodule"x"{\n  source = "./m"\n}\n'
rules "a module without spaces" 3 "storage.tf adds"
append storage.tf '\n/**/ module "m" { source = "./m" }\n'
rules "a module after an inline comment" 3 "storage.tf adds"
mkdir -p "$tier/m" && printf 'data "terraform_remote_state" "x" {\n  backend = "http"\n}\n' > "$tier/m/main.tf"
rules "configuration in a subdirectory" 3 "a subdirectory of the tier"
printf '{}\n' > "$tier/files/x.tf.json"
rules "JSON configuration in a subdirectory" 3 "a subdirectory of the tier"
{ printf 'provider "azurerm" {\n  alias = "x"\n}\n'; for _ in $(seq 1 20000); do echo '# padding padding padding padding'; done; } > "$tier/aaa.tf"
rules "a new provider block, then a large file" 3 "aaa.tf adds"
append storage.tf '\n/**/ provider "azurerm" { alias = "y" }\n'
rules "a provider after an inline comment" 3 "storage.tf adds"
append storage.tf '\nresource "x" "y" {\n  provider = azurerm.y\n}\n'
rules "a provider meta-argument" 3 "storage.tf adds"
ln -s ../environments/compute-production.tfvars "$tier/link.tf"
rules "a symbolic link .tf" 3 "the tier contains a symbolic link"
rm "$envdir/compute-production.tfvars" && ln -s /etc/hosts "$envdir/compute-production.tfvars"
rules "a symbolic link tfvars" 3 "the tier's tfvars file is a symbolic link"
printf '*.tf -diff\n' > "$repo/.gitattributes"
append storage.tf '\nprovider "azurerm" {\n  alias = "z"\n}\n'
rules ".gitattributes -diff with a provider" 3 "storage.tf adds"
mkdir -p "$tier/terraform.d/plugins"
rules "terraform.d" 3 "the tier has an override file"
printf '{}\n' > "$tier/x.tf.json"
rules ".tf.json" 3 "the tier has an override file"
printf 'resource "x" "y" {}\n' > "$tier/storage_override.tf"
rules "an override file" 3 "the tier has an override file"
rc=0; BASE_SHA=$base "$work/tier-rules.sh" identity "$repo" > /dev/null 2>&1 || rc=$?
expect "rules: unknown tier" 2 "$rc"
rc=0; BASE_SHA=nope "$work/tier-rules.sh" compute "$repo" > /dev/null 2>&1 || rc=$?
expect "rules: no base" 2 "$rc"

echo "passed $pass, failed $fails"
[ "$fails" -eq 0 ]
