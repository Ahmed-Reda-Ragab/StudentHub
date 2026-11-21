# ECR repository (CONVENTIONS §2). Long-lived on purpose: images outlive the ephemeral stacks,
# so a destroyed-and-recreated stack can redeploy the exact same SHA.

resource "aws_ecr_repository" "app" {
  name = var.ecr_repository_name

  # A tag (git short SHA) can never be overwritten: "what runs" is always reproducible,
  # and `latest` cannot drift under a running deployment.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  # Basic scanning (free, OS packages) on every push; Trivy in CI covers app dependencies.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Untagged layers/manifests (failed or superseded pushes) after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        # "any" must be the lowest-priority rule. 30 releases = plenty of rollback targets,
        # and storage stays a few cents.
        rulePriority = 2
        description  = "Keep only the last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
