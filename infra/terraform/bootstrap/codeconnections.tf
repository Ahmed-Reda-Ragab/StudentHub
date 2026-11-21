# CodeConnections (formerly CodeStar Connections) — lets CodePipeline (stack 36) read the
# GitHub repo through the AWS Connector for GitHub app, without a personal access token.
#
# Terraform can only create it in PENDING state. One-time manual handshake:
#   Console -> Developer Tools -> Settings -> Connections -> student-app-github
#   -> "Update pending connection" -> authorize / install the "AWS Connector for GitHub" app
#      on Ahmed-Reda-Ragab/StudentHub -> Connect.   Status: PENDING -> AVAILABLE
# Check:  aws codeconnections get-connection --connection-arn <codeconnections_arn> \
#           --query Connection.ConnectionStatus

resource "aws_codeconnections_connection" "github" {
  count = var.create_codeconnection ? 1 : 0

  name          = "${var.project}-github" # max 32 chars
  provider_type = "GitHub"
}
