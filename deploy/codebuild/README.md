# deploy/codebuild — AWS CodeBuild buildspecs (scenarios 35, 36, 58)

| Buildspec | Project | What it does |
|---|---|---|
| [`buildspec-ci.yml`](buildspec-ci.yml) | `student-app-ci` (stack 35) | PHP 8.3 runtime, `composer install`, `pint --test`, `php artisan test` → JUnit report group |
| [`buildspec-build.yml`](buildspec-build.yml) | `student-app-image` (stack 35), `student-app-lab-pipeline-image` (stack 36) | ECR login, `docker build -f docker/Dockerfile --build-arg APP_VERSION=<short sha>`, push the SHA tag (skips if it exists — the repo is immutable), writes `imagedefinitions.json`, `imageDetail.json`, `taskdef.json`, `appspec.yaml` |
| [`buildspec-deploy-ecs.yml`](buildspec-deploy-ecs.yml) | `student-app-lab-pipeline-deploy` (stack 36) | render + register a revision with the new image, one-off migration task, then (`DEPLOY_STEP=all`) `update-service` and wait for `COMPLETED` |

Image: `aws/codebuild/standard:8.0` (Ubuntu 24.04, PHP 8.2–8.5 runtimes, Docker). The buildspec pins
`runtime-versions: php: 8.3` (CONVENTIONS §2) instead of trusting the image default.

## Run by hand

```bash
aws codebuild start-build --project-name student-app-ci --source-version devops-lab
aws codebuild start-build --project-name student-app-image --source-version master
aws codebuild batch-get-builds --ids <build-id> --query 'builds[0].buildStatus'
```

## CodeBuild-hosted GitHub Actions runner (`enable_gha_runner = true` in stack 35)

The `student-app-gha-runner` project has a webhook on `WORKFLOW_JOB_QUEUED`; any job that asks for
it runs on a fresh CodeBuild container with the **project's IAM role** (no OIDC, no stored keys):

```yaml
jobs:
  build:
    runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
    steps:
      - uses: actions/checkout@v6
      - run: docker build -f docker/Dockerfile -t student-app:test .
```

Per-job overrides (image, instance size, fleet) use the multi-line label form from the CodeBuild
"GitHub Actions runner" docs, for example:

```yaml
    runs-on:
      - codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
      - image:arm-3.0
      - instance-size:medium
```

## Gotchas

- Docker Hub rate-limits anonymous pulls from shared CodeBuild IPs (`serversideup/php`, `node`):
  map `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` from SSM (`parameter_store_variables`) or use an
  ECR pull-through cache.
- `LOCAL_DOCKER_LAYER_CACHE` only helps when builds land on the same host shortly after each other.
- Variables set in one command persist to later commands (buildspec 0.2 runs one shell per build).
