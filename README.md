# .github

Reusable GitHub Actions workflows for Talieisin repositories (`ci-*`,
`auto-merge`, `secret-scan`, `dependabot-upgrade`, `copilot-response`),
consumed via thin per-repo callers pinned `@main`.

Exception: `terraform-plan.yml` (Talieisin/caersid's Terraform plan on pull
requests) is called at an exact commit SHA, and Azure trusts the plan identity
only for that SHA. Moving the pin means adding a federated credential for the
new SHA before the bump merges; the workflow's header has the details.

Operational documentation for the org's automation is maintained internally.
