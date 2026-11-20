# AGENTS.md: Talieisin/.github

Reusable GitHub Actions workflows that every Talieisin repository calls. A change here reaches all of them, so treat it as org-wide.

## Credential pipeline: reviewed like a Terraform PR

These paths hold or mint cloud credentials for Terraform plan or apply, or decide what such a job runs. A PR that touches any of them counts as a **Terraform PR** under the github-pr skill: it gets an independent review (a judge, Codex, or another lane) at a named head SHA, and it merges only at that SHA, without `--auto`.

- `.github/workflows/terraform-plan.yml`: caersid's pinned Terraform plan workflow (caersid #602).
- `tools/tfguard/**`: the plan workflow's HCL rules. Its source is embedded in `terraform-plan.yml`, and the tests check that the two copies are identical.
- `tests/terraform-plan/**`: the tests that guard both.
- `.github/workflows/terraform-apply.yml`: the apply-on-merge workflow, once it exists (`docs/design/terraform-apply-on-merge.md`).

No Terraform root is applied from this repository, so there's no plan to run here. A pipeline change's reviewer reads the diff, plus the plan of any caersid root whose plan the change would alter.

## Pinning

- Most callers pin these workflows `@main`.
- **`terraform-plan.yml` is the exception.** caersid pins it at an exact commit, and Azure trusts that commit only. A change to it affects nothing until caersid's pin moves.
  - Before a pin bump merges, George, and only George, adds the federated credential for the new SHA from his own terminal. No agent or workflow creates one.
  - After a merge, tell the caersid lane the merge commit SHA.

## Checks before a PR

- `bash tests/terraform-plan/run.sh` (needs `yq`, `jq`, `shellcheck` and `go`; a missing tool fails it).
- `go test ./...` in `tools/tfguard`, after any change there. Then copy `main.go`, `go.mod` and `go.sum` into the embedded heredocs in `terraform-plan.yml`.
- `actionlint` on any changed workflow.

## Conventions for workflows here

- **Pin third-party actions** by full commit SHA, with the version in a comment.
- **Least privilege:** explicit `permissions` per job, and `persist-credentials: false` on checkouts.
- **No action code in a job that holds `id-token: write`.** Fetch, install and verify inline, with checksums recorded in the file.
- **Inputs reach scripts through `env`,** never `${{ }}` inside a `run` script.
- **Fail closed:** anything a check can't read or classify refuses, with a fixed message.
