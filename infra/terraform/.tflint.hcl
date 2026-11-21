# TFLint config for every root module and module under infra/terraform.
#
# `tflint --recursive` loads the .tflint.hcl of EACH directory it visits, so CI passes this file
# explicitly with an absolute path (see the terraform job in .github/workflows/lint-infra.yml):
#   tflint --init --config "$PWD/infra/terraform/.tflint.hcl"
#   tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl"

config {
  # Also inspect calls into ../../modules/* with the caller's variable values.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # deep_check calls AWS APIs (e.g. "does this AMI exist"); CI lints without credentials.
  deep_check = false
}

# Every variable and output is documented in this repo; keep it that way.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}
