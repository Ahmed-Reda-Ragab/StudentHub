# modules/codedeploy

CodeDeploy application, deployment group and service role.

| `compute_platform` | Scenario | Targets | Traffic |
|---|---|---|---|
| `ECS` | 55 | ECS service with `deployment_controller = CODE_DEPLOY` | blue/green on the ALB listener (`ECSAllAtOnce`, `ECSCanary10Percent5Minutes`, `ECSLinear10PercentEvery1Minutes`, ...) |
| `Server` | 37 | ASG names and/or EC2 tags, CodeDeploy agent on the instances | `IN_PLACE` (deregister → hooks → re-register) or `BLUE_GREEN` (copies the ASG) |

Revisions: ECS uses [`deploy/ecs/appspec.yaml`](../../../../deploy/ecs/appspec.yaml), Server uses
[`deploy/codedeploy/ec2/`](../../../../deploy/codedeploy/ec2/).

Caveats:

- ECS: CodeDeploy rewrites the **listener default action** of `modules/alb`. Stack 50 therefore sets
  `weights_managed_externally = true` on the alb module when `deployment_controller = "CODE_DEPLOY"`:
  Terraform creates the listener once and ignores later `default_action` changes, so an apply never
  shifts traffic back. (Switching controller families recreates the listener — brief outage on :80.)
- Server `BLUE_GREEN` replaces the ASG with a copy that Terraform does not know about — use in-place for
  the Terraform-managed ASG of stack 40.
