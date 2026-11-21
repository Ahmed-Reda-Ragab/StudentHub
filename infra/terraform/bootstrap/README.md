# bootstrap — one-time account setup (scenarios 02, 30, 80)

Long-lived foundation every other stack and workflow depends on. Apply it **once per account** from
your laptop (admin credentials), then leave it alone. It is not part of the Terraform workflow.

| File | Creates |
|---|---|
| `main.tf` | S3 state bucket `student-app-tfstate-<account_id>`: versioning, SSE, public access block, TLS-only policy, old versions expire after 90 days |
| `github-oidc.tf` | GitHub OIDC provider + roles `student-app-gha-ci`, `-deploy`, `-terraform` (admin, gated), `-terraform-plan` (read-only) |
| `ecr.tf` | ECR `student-app`: IMMUTABLE tags, scan on push, keep 30 images, untagged expire after 7 days |
| `codeconnections.tf` | CodeConnections GitHub connection for CodePipeline (manual handshake, see below) |
| `ansible-ssm.tf` | S3 transfer bucket for Ansible over SSM (`ansible_ssm_bucket`, objects expire after 1 day) |

## Apply (local state first)

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars      # optional: defaults match CONVENTIONS
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Move the state into the bucket it just created

```bash
terraform output -raw backend_hcl > ../backend.hcl  # bucket / region / use_lockfile / encrypt
# uncomment the backend "s3" block in versions.tf (key = "bootstrap/terraform.tfstate"), then:
terraform init -migrate-state -backend-config=../backend.hcl
terraform plan                                      # must say: No changes
rm terraform.tfstate terraform.tfstate.backup
```

## Wire GitHub (CONVENTIONS §9)

```bash
terraform output github_repository_variables
# with the GitHub CLI:
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | select(.value != "" and .value != null) | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done   # empty values (disabled features) are skipped
```

Then create the GitHub environment `lab` (Settings → Environments). `terraform.yml` runs apply/destroy
under it; add yourself as a required reviewer to get an approval gate on infrastructure changes.

## CodeConnections handshake (once)

Terraform can only create the connection as `PENDING`. Console → Developer Tools → Settings →
Connections → `student-app-github` → **Update pending connection** → install/authorize the
*AWS Connector for GitHub* app on the repo → **Connect**. Status becomes `AVAILABLE`.

## Role design

| Role | Trusted `sub` | Permissions |
|---|---|---|
| `student-app-gha-ci` | `ref:refs/heads/{main,master}` | push/pull the `student-app` repo only |
| `student-app-gha-deploy` | main/master + `environment:{lab,production}` | ECS update/run-task + PassRole to `student-app-lab-*` (ECS only), SSM Run Command on `Project=student-app` instances, `/student-app/*/deploy/*` params, ASG refresh, listener weights, CodeDeploy, `eks:DescribeCluster`, alarms |
| `student-app-gha-terraform` | `environment:lab` only (required reviewers = the approval gate; no branch subject — also restrict the `lab` environment's *deployment branches* to main/master, the subject carries no ref) | `AdministratorAccess` (lab shortcut; see the comment in `github-oidc.tf` for how to tighten) |
| `student-app-gha-terraform-plan` | `pull_request` + any branch | `ReadOnlyAccess` + decrypt SecureStrings (plans need them to refresh) |

Fork PRs never receive an OIDC token, so only collaborators' branches can use the plan role.

## Cost

S3 state + ECR storage: cents per month. OIDC, IAM, CodeConnections: free.

## Destroy (only when leaving the lab for good)

Destroy every stack first, then copy the state back to local (comment out the backend block,
`terraform init -migrate-state`), set `ecr_force_delete = true` and `state_bucket_force_destroy = true`,
`terraform apply`, then `terraform destroy`.

## Outputs

`account_id`, `region`, `state_bucket`, `github_oidc_provider_arn`, `github_ci_role_arn`, `github_deploy_role_arn`,
`github_terraform_role_arn`, `github_terraform_plan_role_arn`, `ecr_repository_url`, `codeconnections_arn`,
`codeconnections_status`, `backend_hcl`, `github_repository_variables`.
