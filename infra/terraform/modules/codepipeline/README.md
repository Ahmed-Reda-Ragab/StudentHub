# modules/codepipeline

CodePipeline **V2** with a push trigger (branch + file-path filter), `QUEUED` execution mode and a
private, encrypted, auto-expiring artifact bucket.

```
Source (CodeConnections) ─▶ Build (CodeBuild: image, imagedefinitions.json, imageDetail.json, taskdef.json, appspec.yaml)
   ─▶ [Approve (Manual)] ─▶ Deploy: [Migrate (CodeBuild)] ─▶ ECS | CodeDeployToECS | CodeBuild deployer
```

| `deploy_mode` | Deploy action | Service needs |
|---|---|---|
| `ecs` | `ECS` provider, `imagedefinitions.json` | `deployment_controller = ECS` (rolling or native B/G/linear/canary) |
| `codedeploy-ecs` | `CodeDeployToECS`, `taskdef.json` + `appspec.yaml`, `<IMAGE1_NAME>` | `deployment_controller = CODE_DEPLOY` + `modules/codedeploy` |
| `codebuild` | CodeBuild runs `buildspec-deploy-ecs.yml` (migrate + update-service + wait) | `ECS` controller |

The CodeBuild projects themselves come from `modules/codebuild` (see stack 36).
