# .github

Reusable GitHub Actions workflows for Talieisin repositories, consumed through thin per-repo callers pinned `@main`:
- `ci-*`;
- `auto-merge`;
- `secret-scan`;
- `dependabot-upgrade`, with `copilot-response`;
- `claude-command`.

## The Terraform plan workflow is pinned by SHA

`terraform-plan.yml` (Talieisin/caersid's Terraform plan on pull requests, caersid #602) is the exception. caersid calls it at an exact commit SHA, and Azure trusts the plan identity only for that SHA. So a change here has no effect until caersid's pin moves.

Moving the pin needs a federated credential for the new SHA before the bump merges. Only George creates it, from his own terminal; no agent or workflow does. The workflow's header has the details.

## Layout

- **`.github/workflows/`:** the reusable workflows, plus `test-terraform-plan.yml`, which runs the Terraform plan workflow's tests here.
- **`tools/tfguard/`:** the plan workflow's HCL rules (Go). The workflow embeds the same source, and the tests check the copies match.
- **`tests/terraform-plan/`:** tests of the plan workflow's guard logic.
- **`docs/design/`:** designs, including the draft apply-on-merge design for caersid. A design isn't approval to build it.
- **`AGENTS.md`:** instructions for coding agents working here: which paths are reviewed like Terraform, which checks to run, the workflow conventions.

Operational documentation for the org's automation is maintained internally.
