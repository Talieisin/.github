# Terraform apply on merge (caersid): design

Status: draft for George's review. Revised after two independent judge reads: 2026-11-19 (1 must-fix, 6 should-fix) and 2026-11-20 (3 must-fix, 6 should-fix, 4 nits), all taken. Nothing here is built.
Depends on: the pinned plan workflow (Talieisin/.github#44, `178c5d9`) being live in caersid. That means caersid's caller pinned to it, the OIDC subject template switched, and the plan identity's federated credential added.

## 1. Goal and the approval model

When George merges a Terraform pull request into caersid's `main`, CI applies **exactly the plan that was reviewed on that pull request**, and nothing else.

The human review is George's existing process, not a new technical gate:

- the plan runs on the pull request (the #44 workflow);
- George confirms the changes are the expected ones;
- Codex or a judge reviews independently;
- **merging is the approval**, by George or by an agent acting on his instruction.

The pipeline's job is to make that approval binding: what applies must be what was approved. This follows the published practice:

- HashiCorp, "Running Terraform in automation": manual review of plans is strongly recommended for production, and "ensure that the correct plan is applied".
- Microsoft Learn: apply on push to main "after a manual review has signed off".
- Google: "After an infrastructure owner approves it, execute the plan."
- HCP Terraform: plans need confirmation by default; real runs start on merge.

Out of scope:
- the identity tier, which George alone plans and applies, as now;
- apply before merge (the Atlantis model);
- any apply not triggered by a merge to `main`.

## 2. Flow

```
PR (George's signed pushes)          main (after George's merge)
---------------------------          ----------------------------------------
plan workflow (#44)                  apply workflow (new, pinned like #44)
  - names-only summary                 gate: the push is the merge of one PR
  - FINGERPRINT per tier (new)         that passed the plan gate, same tree
George: plan.sh shows the same       re-plan main with the apply identity
  fingerprint; expected changes      fingerprint == the PR's? -> apply the
Codex or judge: independent review     saved plan from this run
George merges = approval             otherwise: stop, comment, George
                                       applies locally
```

### 2.1 Fingerprint (added to the plan workflow)

The fingerprint must equal across honest plans of the same change. Those plans come from three identities on the same state: CI's plan identity, George's local `plan.sh`, and the apply identity. It must differ when the change differs. So it covers **only what apply will change**, never the refreshed state as a whole.

**What goes in the hash:** per tier, `sha256` over a canonical JSON (`jq -S`, fixed fields) of the `resource_changes` entries whose actions are not `no-op` or `read`. For each entry:
- the address, `previous_address` and `deposed`;
- the actions, `replace_paths` and `importing`;
- the paths whose value differs between `before` and `after`, with their `after` value;
- the `after_unknown` paths;
- `output_changes` entries that change, with their actions, `after` values and `after_unknown`, so an output that becomes unknown can't match one that becomes `null`.

**What stays out:**
- unchanged attributes, no-op resources and `resource_drift`;
- anything an identity's view of the state can colour, such as a shared key that one identity reads as blank. The platform plan identity can't read the Log Analytics key; the apply identity can.

A deploy that changes `azurerm_container_app.this`'s image between plan and merge shows up only if apply would change it.

**Proved before anything is built (rollout step 0):** the same commit, planned against the same state by the plan identity, by George locally and by the apply identity, gives the same fingerprint. Terraform's version is the same for all three: the workflow's checksummed release and George's mise pin.

**Where it is shown:**
- **The PR comment** shows each tier's fingerprint together with the plan run's id and the full head SHA.
- **caersid's `scripts/plan.sh`** prints the same fingerprint, using the same canonicalisation script, so George's review of the full local plan is tied to CI's by one visible value.

### 2.2 Apply workflow (hub: `terraform-apply.yml`, caersid: caller on push to main)

The caller runs on `push` to `main` with `paths: infrastructure/terraform/**`. The concurrency group belongs to the **hub's apply job** (job-level `concurrency`, `cancel-in-progress: false`), not to the caller, because every gate lives in the pinned file.
- One apply runs at a time, and a running one is never cancelled.
- GitHub keeps only one *pending* run per group, so with three quick merges the middle one's queued run is dropped. Each run therefore reads the last applied commit from its own record: the head of the most recent apply run that reached `applied`, found through the Actions runs API for the pinned apply workflow. It then lists the merges since that commit that it supersedes, and comments on those PRs.
- Its plan covers their changes, because head-only plans with the "behind main" rule mean each PR already contained the earlier merges.

1. **gate** (no credentials, no checkout). From the API, the pushed commit must meet all of these:
   - **It is the merge commit of exactly one merged PR.**
     - `GET /commits/{sha}/pulls` finds the PR.
     - The gate then reads `GET /pulls/{n}`, because the list items carry no `merged_by`.
     - `merge_commit_sha` must equal the push.
   - **The PR was merged by a person with the admin or maintain role on caersid** (decision 1). Checked through the API at apply time:
     - `merged_by.type` is `User`, so GitHub Apps and bots are refused;
     - `GET /repos/{repo}/collaborators/{login}/permission` gives `role_name` `admin` or `maintain`. `role_name` is the field to use: `permission` reports maintain as write.
     - A consistency check, not an allowlist: the permission response's `user.id` must equal `merged_by.id`, so the role looked up is the merger's own even if the account was renamed or deleted (`ghost`). Any account with the role qualifies; no account is named.

     That covers both of George's accounts, and his agents acting as him.
   - **The PR's head passed the plan gate**, and its fingerprint comes from that run, not from the comment. The plan workflow gets a final credential-less job that uploads one artefact, with a name fixed in the hub file. It holds:
     - the full head SHA and the run id;
     - each tier's state (`planned` or not);
     - each tier's fingerprint;
     - each tier's refused-type check (2.2, step 2).

     The gate:
     - refuses if the PR changed caersid's caller workflows (`.github/workflows/terraform-plan.yml` or `terraform-apply.yml`). A sibling job in a changed caller could otherwise upload an artefact first. Such a PR is applied locally;
     - finds the latest plan run for the PR's exact head SHA, and requires conclusion `success` and `completed_at` before the PR's `merged_at`;
     - checks the run's `referenced_workflows` name the pinned hub plan workflow;
     - downloads the artefact by run id, and requires exactly one artefact of that name, the same head SHA and run id, and every changed tier `planned`.

     Comments are editable by anything with issue write, so they're only for George to read. A run that succeeded but refused a tier (a refusal exits 0) doesn't count as planned.

     The PR comment shows the same run id. If a reopen re-plans the head, the newer run is the one used, and its fingerprint is the one George sees in the comment at merge time.
   - **The pushed commit's `infrastructure/terraform/` tree is identical to the PR head's,** so nothing else reached that path between plan and merge. With head-only plans and the "behind main" refusal, this normally holds.

   If any check fails, nothing is applied, and the gate comments on the PR saying why.
2. **apply** (`environment: production-apply`, `id-token: write`, no action code; the same structure as #44's plan job):
   - **Setup:** fetches the commit by id, installs the checksummed Terraform (the same version as the PR plan), mints a token file, and runs `init` against the **real azurerm backend**. `init` takes no lock; each `plan` and each `apply` takes the state lock and releases it. The backend needs a credential, so the token comes first. `init` runs in a process with no ID-token request variables.
   - **Plan every changed tier first:** for each, it mints a fresh token file, runs `plan -lock-timeout=5m -out=<tier>.tfplan`, and computes the fingerprint.
   - **Then checks every tier before applying anything.** Nothing applies if any of these fail:
     - each fingerprint equals its artefact fingerprint;
     - no plan touches a **refused type**: any Terraform type whose Azure resource type is `Microsoft.Authorization/*`, plus federated identity credentials and Cosmos SQL role assignments and role definitions (2.3);
     - no plan deletes or replaces a resource under a `CanNotDelete` lock's scope (today: the Cosmos account and the Key Vault, from `locks.tf`). Azure would refuse the delete partway through the apply;
     - no tier has a `provisioner` or `connection` block, in any block, changed or not. `local-exec`, `remote-exec` and `file` run commands on the runner during apply, where the token file is reachable. caersid uses none. The rule goes into tfguard when the apply workflow is built; the plan path isn't affected, because provisioners run only at apply.

     A refused or mismatched tier stops the whole run, with a fixed comment saying why, and George applies locally.
   - **Apply, in order:** platform first, because compute reads platform's outputs. For each tier, it mints a fresh token file immediately before `apply <tier>.tfplan`, because a GitHub ID token lasts only minutes and apply starts new provider and backend processes that exchange it again.
     - Compute applies only if platform applied cleanly or had no changes.
     - If George applies locally between this job's plan and its apply, Terraform rejects the saved plan as stale. That is safe, and it is reported as its own failure class, `stale-plan`.
   - **Report:** posts a names-only result to the PR (applied with its fingerprint, stopped, or failed with its class), and deletes the token and plan files.
3. **Both tiers in one PR** (decision 3: no hard rule, safe handling).
   - A PR may change both tiers. After platform applies, CI re-plans compute and applies it only if its fingerprint still matches the PR's, which it does when platform's outputs didn't change. Otherwise it stops and reports, and George applies compute locally.
   - After a platform apply that changes outputs, the workflow reports a compute plan without applying it, so George sees whether compute now needs an apply.
   - The plan comment warns when a PR changes both tiers.
   - Agent lead sessions (agent-team-lanes) split Terraform work by tier: a platform PR first, then a compute PR planned against the applied platform.
4. **New resource types apply in CI from their first use** (George, 2026-11-20; tfguard change in Talieisin/.github#46). Creating a resource reads nothing that exists, so the plan's rules no longer hold back a resource type main doesn't use yet. Two cases stay local:
   - **a new data-source type** (it reads at plan time);
   - **a new type on the refused list** below.

**Refused-type list, tested:** the refused types are one list in the hub file, matched by Terraform type name. A test in the hub checks that every resource type main uses is classified as either refused or allowed. A newly used type therefore needs a decision; it can't slip past the list.
- **Refused** (Azure resource type `Microsoft.Authorization/*` and the identity and Cosmos access types):
  - `azurerm_role_*`, `azurerm_pim_*` and `azurerm_role_management_policy`;
  - `azurerm_*policy_assignment`, `azurerm_*policy_exemption`, `azurerm_policy_definition` and `azurerm_policy_set_definition`;
  - `azurerm_management_lock`;
  - `azurerm_federated_identity_credential`;
  - `azurerm_cosmosdb_sql_role_assignment` and `azurerm_cosmosdb_sql_role_definition`;
  - `azurerm_key_vault_access_policy`.
- Today, main already uses `azurerm_resource_group_policy_assignment`, so a change to the ingress policy is applied locally.

### 2.3 Identity and trust

- **A new apply identity,** `id-caersid-apply-prod`, created in the identity tier by George. It lives outside every scope the platform and compute tiers manage, so no apply can modify the identity itself or its federated credentials. It gets:
  - a **custom role** on `rg-caersid-prod` built as a deny-list (decision 2): `Actions: ["*"]`, with `NotActions` covering the access-granting actions:
    - `Microsoft.Authorization/*/write` and `Microsoft.Authorization/*/delete` (role assignments, role definitions, locks, policy assignments and exemptions);
    - `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write` and `.../delete`;
    - `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write` and `.../delete`, and `.../sqlRoleDefinitions/write` and `.../delete`.
    - `Actions` grants no `DataActions`.
  - **Two Azure Policy denies,** assigned by George. The identity can't remove them or add exemptions, because policy writes are denied above:
    - Cosmos local (key) authentication must stay disabled. Otherwise `databaseAccounts/write` could turn it on, and `listKeys` would return a key with full data access;
    - the ACR admin user must stay disabled.
  - **On the state container:** **Reader** (the platform refresh reads role assignments scoped to it), a **prefix-limited list** (`terraform init` on the azurerm backend lists blobs), and write and lease on the two state blobs only (ABAC). Lease needs `blobs/write`, so it is granted only at rollout step 5. Nothing on the identity tier's state.

  **Tested before rollout step 3:** `init`, `plan` and a no-op `apply` as this identity against a copy of the container's rules.

  **New resource types:** under the deny-list they need no change to the role, and they apply in CI from their first use (2.2, item 4).
- **The plan identity stays read-only.** It is used only on PRs.
- **The federated credential:** exact subject, no wildcard:
  `repo:Talieisin/caersid:environment:production-apply:job_workflow_ref:Talieisin/.github/.github/workflows/terraform-apply.yml@<sha>`
- **The environment:** `production-apply` in caersid, deployment branch rule `main` only. The Team plan has no required reviewers for private repositories, so the environment restricts branches and doesn't approve anything; the approval is the merge.
- **Pin bumps:** the same rule as for the plan workflow. George adds the credential for a new SHA before the bump merges, from his own terminal.

### 2.4 Reused from #44, unchanged

- no action code in the job that holds the token;
- the token file, with no request variables in Terraform's environment;
- `env -i` for Terraform, and checksummed Terraform;
- fetch by commit id;
- names-only output, no plan artefacts;
- fixed failure text;
- literal identity IDs in the workflow;
- run attempt 1 only, so a re-run never applies.

## 3. Failure handling

- **No retry:** a failed apply is never retried automatically, because a partial apply needs a human. The PR gets a fixed comment, and George continues locally.
- **Locks:** Terraform waits for the state lock only with `-lock-timeout`, set to 5 minutes; after that it fails. A killed job can leave the blob lease held. The runbook needs George's procedure for that (check no apply is running, then `terraform force-unlock` locally). No `-lock=false` for apply.
- **Fingerprint stops:** the check stops an apply when `main` moved, the plan aged, a changed attribute's planned value differs, or one PR changed both tiers and platform's outputs changed. In all of these, nothing applies and George decides.
  - **Not detected:** drift in `before` that leaves the planned `after` the same still matches. The end state is the reviewed one either way.
- **Stale saved plan:** if anything changes the state between this job's plan and its apply (for example George applying locally), Terraform refuses the saved plan. It is reported as `stale-plan`.
- **Long applies:** an apply that outlasts the Entra access token (about an hour) can fail to save state. Terraform then writes `errored.tfstate` locally. The job reports `state-save-failed`, keeps that file only as long as George needs to push it (`terraform state push`), and never prints it.
- **Break-glass:** George's terminal, as today. The apply workflow never blocks a local apply.

## 4. Rollout

0. **Prove the fingerprint (2.1).** Plan the same commit against the same state as the plan identity, as George locally and as a test apply identity, and compare. Nothing else is built until they match.
1. **The plan path is live** (#602).
2. **George creates the apply identity,** with read-only rights for now: container Reader, the prefix list and blob read, no lease, no write role. He also creates the `production-apply` environment and assigns the two policy denies (2.3).
3. **Build and pin:** build `terraform-apply.yml` and the refused-type test in the hub, review them as #44 was reviewed, then pin from caersid with the credential. Test the `init` and `plan` permissions (2.3).
4. **Shadow mode:**
   - A constant in the pinned file, not an input, means the apply step can't run.
   - Plans use `-lock=false`, because the identity has no lease right yet.
   - The workflow runs the gate, the plans, the refusal checks and the fingerprint comparison, and reports what it *would* do.
   - The identity holds no write right on state or resources, so a compromised shadow run can't change production.
   - George waits for each shadow report before applying locally; applying first would make the shadow plan a no-op and report a false mismatch.
5. **Turn on apply:** grant the custom role, and blob write and lease on the two state blobs. Remove the shadow constant in a new pinned commit with its own credential.

## 5. Decisions (George, 2026-11-19)

1. **Who can approve by merging:** any person, not a bot (`User`), with the admin or maintain role on caersid, checked through the API at apply time. No account is named. GitHub App and bot merges never apply.
2. **What CI never applies:** a deny-list, not an allow-list, so new resource types aren't held back by the role or by the plan's rules. They apply in CI from their first use (2.2, item 4; Talieisin/.github#46).
   - The apply identity's custom role is `*` minus the access-granting actions in 2.3, backed by two policy denies.
   - The workflow refuses plans touching the refused types in 2.2, from one tested list, and plans that delete or replace under a lock.
   - Those changes, and the identity tier, stay with George's local apply.
3. **Both tiers in one PR:** handled safely rather than blocked (2.2, item 3). The plan comment warns, and lanes split Terraform work by tier.
4. **The plan comment's footer:** "Merging approves this plan for apply (fingerprint …). Platform role, policy and credential changes, and the identity tier, are applied by George locally."
5. **The fingerprint:** plain SHA-256, so `plan.sh` needs no secret. The theoretical guessing risk (Section 2.1) is accepted as negligible.

## 6. Residual risks (stated, not designed away)

- **A compromised apply job is a production compromise within `rg-caersid-prod`.** The job runs only `main`'s merged code, fetched by commit id, with the same no-action, token-file and clean-environment discipline as the plan job. Under `*` minus the access-granting actions, a compromised apply could still do the following, none of which needs an `Authorization` write:
  - **Run code as other identities in the group.** Through `userAssignedIdentities/assign/action`, Container App writes and exec, deployment scripts or VM run-command, it can act as the app's identity, which has Key Vault secrets and Cosmos data rights. `*` grants no DataActions directly, but those identities reach data.
  - **Take persistent credentials:** storage `listKeys` and `listAccountSas`, ACR tokens or `listCredentials` (the admin user is denied by policy), and Log Analytics keys.
  - **Key Vault stays safe while it is in RBAC mode:** switching its permission model needs a role-assignment write, which is denied.

  These are the cost of a deny-list role; an allow-list would narrow them at the price of the type-by-type upkeep George chose against.
- **Agent merges count as approval (Section 1).** A misled agent merge applies only a plan that matches a reviewed PR plan; it cannot apply anything that was not planned on the PR.
- **The PR plan's known channels** (see #44's header) are unchanged. Apply adds no new code execution: it runs only merged code, and the gate refuses provisioners (2.2), the way Terraform configuration runs commands on the runner at apply.
- **`data.azurerm_client_config` reads differ by identity.** Only `tenant_id` is used today, which is the same for all of them; a new use of another of its fields would show up as a fingerprint mismatch, not a wrong apply.

## 7. Sources

- HashiCorp, Running Terraform in automation: https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform
- HashiCorp, GitHub Actions tutorial (plan on PR, apply on merge): https://developer.hashicorp.com/terraform/tutorials/automation/github-actions
- HCP Terraform run workflow: https://developer.hashicorp.com/terraform/cloud-docs/run/ui
- Microsoft Learn, infrastructure as code with GitHub Actions: https://learn.microsoft.com/devops/deliver/iac-github-actions
- Google Cloud, Terraform best practices (operations, security): https://docs.cloud.google.com/docs/terraform/best-practices/operations
- AWS Prescriptive Guidance, Terraform security (separate plan and apply roles, `sub` plus `ref` scoping): https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/security.html
- GitHub, security hardening and environments: https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
- Atlantis apply requirements and security: https://www.runatlantis.io/docs/command-requirements and https://www.runatlantis.io/docs/security
