# modules/codebuild

A set of CodeBuild projects with one least-privilege role and one log group per project.

- `source_type = "GITHUB"`: source via the **CodeConnections** GitHub App (`auth { type = "CODECONNECTIONS" }`),
  commit status reporting, optional webhook (`PUSH`, `PULL_REQUEST_*`, or `WORKFLOW_JOB_QUEUED` for a
  CodeBuild-hosted GitHub Actions runner).
- `source_type = "CODEPIPELINE"`: started by CodePipeline, reads/writes the pipeline artifact bucket.

Used by [`stacks/35-codebuild`](../../stacks/35-codebuild/) (CI, image, runner) and
[`stacks/36-codepipeline`](../../stacks/36-codepipeline/) (pipeline image + migrate/deploy steps).
Buildspecs: [`deploy/codebuild/`](../../../../deploy/codebuild/).
