config {
  # dry-run so tflint does not exit with a non-zero status (yet)
  force = true
}

plugin "terraform" {
  enabled = true
  version = "0.9.1"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_standard_module_structure" {
  enabled = false
}
