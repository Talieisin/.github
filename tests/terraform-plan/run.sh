#!/usr/bin/env bash
# Tests of the guard logic in .github/workflows/terraform-plan.yml (caersid
# #602). The scripts under test are extracted from the workflow itself, so the
# tests run exactly the text the pinned workflow runs:
#   - the gate's push-chain verdict (jq);
#   - the gate's commit check (jq);
#   - plan-summary.sh: names only, instance keys hidden;
#   - mint-token.sh: audience and subject checks, the 0600 file;
#   - plan-tier.sh: refuses to start with the ID token request variables;
#   - tfguard (the HCL rules): the copy embedded in the workflow is
#     tools/tfguard, byte for byte, and its Go tests pass.
# Also shellchecks every extracted script (a missing shellcheck or go fails).
#
#   tests/terraform-plan/run.sh [workflow file]
#
# Needs bash, git, jq, yq (mikefarah, v4), awk, shellcheck and go.
# Exit 0 when every test passes.
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
for s in mint-token plan-summary check-identity plan-tier; do extract "$s"; done

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


# --- mint-token.sh --------------------------------------------------------------
# A fake curl prints $FAKE_RESP; the claims are what the script must judge.
fake="$work/fakebin"; mkdir -p "$fake"
printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s" "$FAKE_RESP"\n' > "$fake/curl"; chmod +x "$fake/curl"
b64url() { printf '%s' "$1" | base64 | tr -d '=\n' | tr '/+' '_-'; }
jwt_with() { printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2ln' "$(b64url "$1")"; }
WF='Talieisin/.github/.github/workflows/terraform-plan.yml@0123456789abcdef0123456789abcdef01234567'
good=$(jq -cn --arg r "$WF" '{aud: "api://AzureADTokenExchange", repository: "Talieisin/caersid", event_name: "pull_request", job_workflow_ref: $r, job_workflow_sha: "0123456789abcdef0123456789abcdef01234567", sub: ("repo:Talieisin/caersid:pull_request:job_workflow_ref:" + $r)}')
mint() { # <claims json>: exit status of mint-token.sh with that token
  local rc=0
  rm -f "$work/token"
  FAKE_RESP=$(jq -cn --arg v "$(jwt_with "$1")" '{value: $v}') PATH="$fake:$PATH" \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://example.invalid/?x=1' ACTIONS_ID_TOKEN_REQUEST_TOKEN=t \
    "$work/mint-token.sh" "$work/token" > /dev/null 2>&1 || rc=$?
  echo "$rc"
}
expect "mint: a good token" 0 "$(mint "$good")"
mode=$(stat -c '%a' "$work/token" 2> /dev/null || stat -f '%Lp' "$work/token")
expect "mint: the file is 0600" 600 "$mode"
expect "mint: another audience" 5 "$(mint "$(jq -c '.aud = "api://other"' <<<"$good")")"
expect "mint: the default subject" 5 "$(mint "$(jq -c '.sub = "repo:Talieisin/caersid:pull_request"' <<<"$good")")"
expect "mint: another workflow file" 5 "$(mint "$(jq -c '.job_workflow_ref = "Talieisin/.github/.github/workflows/other.yml@x" | .sub = ("repo:Talieisin/caersid:pull_request:job_workflow_ref:" + .job_workflow_ref)' <<<"$good")")"
expect "mint: another repository" 5 "$(mint "$(jq -c '.repository = "Talieisin/other"' <<<"$good")")"
expect "mint: another event" 5 "$(mint "$(jq -c '.event_name = "push"' <<<"$good")")"
rc=0; PATH="$fake:$PATH" "$work/mint-token.sh" "$work/token" > /dev/null 2>&1 || rc=$?
expect "mint: no request variables" 5 "$rc"

# --- plan-tier.sh ----------------------------------------------------------------
: > "$work/jwt"
rc=0; RUNNER_TEMP=$work ACTIONS_ID_TOKEN_REQUEST_URL=x "$work/plan-tier.sh" platform "$work/s.md" "$work/jwt" > /dev/null 2>&1 || rc=$?
expect "plan-tier: refuses the request variables" 2 "$rc"

# --- tfguard ---------------------------------------------------------------------
gosrc=$(yq '.jobs.prepare.steps[] | select(.name == "Build tfguard") | .run' "$wf")
for f in go.mod go.sum main.go; do
  awk -v f="$f" '
    $0 == "cat > \"$src/" f "\" <<'"'"'GOSRC'"'"'" { on = 1; next }
    on && $0 == "GOSRC" { on = 0; next }
    on { print }' <<<"$gosrc" > "$work/embedded-$f"
  if cmp -s "$work/embedded-$f" "$here/../../tools/tfguard/$f"; then ok; else bad "tfguard: the workflow's $f is not tools/tfguard/$f"; fi
done
if ! command -v go > /dev/null 2>&1; then
  bad "go is not installed: tfguard's tests did not run"
elif (cd "$here/../../tools/tfguard" && GOFLAGS=-mod=readonly go test ./... > "$work/go-test.log" 2>&1); then ok
else bad "tfguard: go test failed"; cat "$work/go-test.log"; fi

echo "passed $pass, failed $fails"
[ "$fails" -eq 0 ]
