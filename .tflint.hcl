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

rule "aws_resource_missing_tags" {
  enabled = false
  exclude = [
    # this is covered by the propagation already
    "aws_autoscaling_group",
    # this has to be enabled on the account level which may break things
    "aws_ecs_service"
  ]
  #tags = [""]
}
