# AGENTS.md: Talieisin/.github

The README covers what this repository is, how it's consumed and the SHA-pin policy for `terraform-plan.yml`. This file says how to work on it. Every Talieisin repository calls these workflows, so treat any change as org-wide.

## Credential pipeline: a Terraform PR

These paths hold or mint cloud credentials for Terraform plan or apply, or decide what such a job runs. A PR touching any of them is a **Terraform PR** under the github-pr skill: it gets an independent review (a judge, Codex, or another lane) at a named head SHA, and it merges only at that SHA, without `--auto`.

- `.github/workflows/terraform-plan.yml`
- `tools/tfguard/**`
- `tests/terraform-plan/**`
- `.github/workflows/terraform-apply.yml` (once it exists; see `docs/design/terraform-apply-on-merge.md`)

No Terraform root is applied from this repository. The reviewer of a pipeline change reads the diff, plus the plan of any caersid root whose plan the change would alter.

## Before a PR

- `bash tests/terraform-plan/run.sh` (needs `yq`, `jq`, `shellcheck` and `go`; a missing tool fails it).
- After a change in `tools/tfguard`: `go test ./...` there. Then copy `main.go`, `go.mod` and `go.sum` into the embedded heredocs in `terraform-plan.yml` (the tests fail until they match).
- `actionlint` on any changed workflow.

## After a merge

- If `terraform-plan.yml`, `tools/tfguard` or the apply workflow changed, send the caersid lane the merge commit SHA. caersid moves its pin to it.
- **Never create or change a federated credential.** George does that (README).

## Conventions for workflows here

- **Pin third-party actions** by full commit SHA, with the version in a comment.
- **Least privilege:** explicit `permissions` per job, and `persist-credentials: false` on checkouts.
- **No action code in a job that holds `id-token: write`.** Fetch, install and verify inline, with checksums recorded in the file.
- **Inputs reach scripts through `env`,** never `${{ }}` inside a `run` script.
- **Fail closed:** anything a check can't read or classify refuses, with a fixed message.
