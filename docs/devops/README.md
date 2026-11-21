# StudentHub DevOps / SRE Lab — خريطة الطريق

> مشروع Laravel حقيقي (Students Subscriptions) بنستخدمه معمل كامل نتعلم عليه **كل طرق الـ deploy على AWS**،
> من EC2 + Docker Compose لحد ECS و EKS. كل سيناريو بيتعمل **مرتين**: مرة من **AWS Console** ومرة بـ **Terraform + Ansible**،
> مع CI/CD على **GitHub Actions** و **AWS CodeBuild/CodePipeline/CodeDeploy**، وكل أنواع الـ **zero-downtime deployment**،
> ومفاهيم الـ **SRE** بنقيسها بجد (SLO، error budget، burn rate، load testing، chaos).

- **العقد (الأسماء والبورتات والمتغيرات والـ SLOs):** [CONVENTIONS.md](CONVENTIONS.md)
- **قالب أي سيناريو:** [_scenario-template.md](_scenario-template.md)
- **الملخص الشامل (PDF):** [SUMMARY.pdf](SUMMARY.pdf) · المصدر: [SUMMARY.md](SUMMARY.md) · كل السيناريوهات في ملف واحد: [HANDBOOK.pdf](HANDBOOK.pdf)

---

## إزاي تستخدم المعمل ده

1. اقرا [01 — الأدوات](scenarios/01-tools-primer.md) و [CONVENTIONS](CONVENTIONS.md).
2. جهّز الحساب والجهاز ([02](scenarios/02-aws-account-setup.md)، [03](scenarios/03-workstation-setup.md)).
3. امشِ على المسارات بالترتيب. كل سيناريو فيه: **Console ← IaC ← Deploy ← Verify ← Break it ← Rollback ← Teardown ← Cost ← Interview**.
4. **من غير Docker على جهازك؟** كل اللي محتاج Docker بيشتغل على GitHub Actions:
   - [`lab-integration.yml`](../../.github/workflows/lab-integration.yml): compose، k6، والـ zero-downtime scripts
   - [`k8s-integration.yml`](../../.github/workflows/k8s-integration.yml): kind و Helm و Argo Rollouts
   - [`ci.yml`](../../.github/workflows/ci.yml): الـ tests والـ image وTrivy
5. **اعمل teardown بعد كل سيناريو فيه موارد AWS.** راجع [97 — التكلفة والمسح](scenarios/97-cost-and-teardown.md).

```text
                       ┌──────────── A. الأساسيات (01–03)
                       ▼
        B. Containers (10–12) ──► C. EC2 single host (20–27) ──► D. CI/CD (30–37)
                                          │                            │
                                          ▼                            ▼
                               E. EC2 at scale (40–49) ◄───────────────┘
                                          │
                     ┌────────────────────┼────────────────────┐
                     ▼                    ▼                    ▼
              F. ECS (50–58)     G. Kubernetes/EKS (60–6A)   H. Observability & SRE (70–77)
                     └────────────────────┼────────────────────┘
                                          ▼
                     I. Security (80–83) · J. IaC deep dives (90–93) · K. Wrap-up (95–99)
```

---

## الكتالوج (كل سيناريو ليه ملف)

### A. الأساسيات

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 01 | [نبذة عن كل tool بنستخدمها](scenarios/01-tools-primer.md) | — | — | مجاني |
| 02 | [تجهيز حساب AWS (MFA، Identity Center، Budgets، CLI، bootstrap)](scenarios/02-aws-account-setup.md) | ✅ | ✅ | ~$0 |
| 03 | [تجهيز الجهاز (WSL2، Docker، Ansible، Terraform، kubectl، helm، k6)](scenarios/03-workstation-setup.md) | — | — | مجاني |

### B. الـ Containers

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 10 | [تحويل التطبيق لـ container (Dockerfile + Compose + MySQL)](scenarios/10-containerize-app.md) | — | ✅ | مجاني |
| 11 | [تقوية الـ image (non-root، الحجم، multi-arch، SBOM، Trivy، cosign)](scenarios/11-image-hardening.md) | — | ✅ | مجاني |
| 12 | [SRE lab endpoints + Prometheus/Grafana محلي + k6](scenarios/12-sre-lab-endpoints-and-local-observability.md) | — | ✅ | مجاني |

### C. EC2 — سيرفر واحد

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 20 | [EC2 + Docker Compose + MySQL container، build على السيرفر (Console)](scenarios/20-ec2-compose-console.md) | ✅ | — | ~$0.72/يوم |
| 21 | [نفس الحاجة بـ Terraform + Ansible](scenarios/21-ec2-compose-terraform-ansible.md) | — | ✅ | ~$0.72/يوم |
| 22 | [Recreate وقياس الـ downtime](scenarios/22-recreate-and-measuring-downtime.md) | ✅ | ✅ | نفس 20 |
| 23 | [Blue/Green على سيرفر واحد (nginx switch)](scenarios/23-bluegreen-single-host.md) | ✅ | ✅ | نفس 20 |
| 24 | [Canary على سيرفر واحد (weights + metric gate + auto-abort)](scenarios/24-canary-single-host.md) | ✅ | ✅ | نفس 20 |
| 25 | [Rolling update بأكتر من replica](scenarios/25-rolling-single-host.md) | ✅ | ✅ | نفس 20 |
| 26 | [A/B testing و Shadow traffic و Feature flags](scenarios/26-ab-testing-shadow-feature-flags.md) | ✅ | ✅ | نفس 20 |
| 27 | [Backup لـ MySQL على S3 + تجربة restore](scenarios/27-mysql-backup-restore.md) | ✅ | ✅ | سنتات |

### D. CI/CD

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 30 | [CI على GitHub Actions (tests، scans، ECR بـ OIDC)](scenarios/30-ci-github-actions.md) | ✅ | ✅ | مجاني/سنتات |
| 31 | [CD → EC2 بـ SSH + build على السيرفر (الطريقة القديمة)](scenarios/31-cd-ec2-ssh-build-on-server.md) | ✅ | ✅ | نفس 20 |
| 32 | [CD → EC2 بـ ECR + SSM Run Command](scenarios/32-cd-ec2-ecr-ssm.md) | ✅ | ✅ | نفس 20 |
| 33 | [CD → EC2 بـ Ansible](scenarios/33-cd-ec2-ansible.md) | — | ✅ | نفس 20 |
| 34 | [Environments و approvals و promotion و rollback](scenarios/34-environments-approvals-promotion.md) | ✅ | ✅ | مجاني |
| 35 | [AWS CodeBuild (buildspec، webhook، GitHub Actions runners)](scenarios/35-aws-codebuild.md) | ✅ | ✅ | سنتات |
| 36 | [AWS CodePipeline](scenarios/36-aws-codepipeline.md) | ✅ | ✅ | ~$1/شهر |
| 37 | [AWS CodeDeploy لـ EC2/ASG](scenarios/37-aws-codedeploy-ec2.md) | ✅ | ✅ | نفس 42 |

### E. EC2 على نطاق أكبر

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 40 | [VPC من الصفر](scenarios/40-vpc-from-scratch.md) | ✅ | ✅ | مجاني (من غير NAT) |
| 41 | [RDS MySQL + نقل الداتا من الـ container](scenarios/41-rds-mysql.md) | ✅ | ✅ | ~$0.5/يوم |
| 42 | [ALB + ASG + Launch Template + ACM/Route 53](scenarios/42-alb-asg-launch-template.md) | ✅ | ✅ | ~$2/يوم |
| 43 | [Golden AMI بـ Packer + Ansible](scenarios/43-golden-ami-packer.md) | ✅ | ✅ | سنتات |
| 44 | [Rolling بـ ASG Instance Refresh](scenarios/44-rolling-instance-refresh.md) | ✅ | ✅ | نفس 42 |
| 45 | [Blue/Green بـ اتنين ASG + listener switch](scenarios/45-bluegreen-two-asgs.md) | ✅ | ✅ | نفس 42 |
| 46 | [Canary بـ weighted target groups + alarm rollback](scenarios/46-canary-weighted-target-groups.md) | ✅ | ✅ | نفس 42 |
| 47 | [Rolling deploy بـ Ansible (serial + drain)](scenarios/47-ansible-rolling-deploy.md) | — | ✅ | نفس 42 |
| 48 | [Autoscaling تحت load](scenarios/48-autoscaling-under-load.md) | ✅ | ✅ | نفس 42 |
| 49 | [ElastiCache Redis للـ sessions/cache (ندوّر على الـ bottleneck)](scenarios/49-redis-sessions-cache.md) | ✅ | ✅ | ~$0.4/يوم |

### F. ECS

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 50 | [ECS Fargate من الـ Console](scenarios/50-ecs-fargate-console.md) | ✅ | — | ~$2.7/يوم |
| 51 | [ECS Fargate بـ Terraform](scenarios/51-ecs-fargate-terraform.md) | — | ✅ | ~$2.7/يوم |
| 52 | [Migrations كـ one-off task + ECS Exec](scenarios/52-ecs-migrations-and-exec.md) | ✅ | ✅ | نفس 51 |
| 53 | [Rolling + circuit breaker rollback](scenarios/53-ecs-rolling-circuit-breaker.md) | ✅ | ✅ | نفس 51 |
| 54 | [Blue/Green و Canary و Linear بـ CodeDeploy](scenarios/54-ecs-codedeploy-bluegreen-canary.md) | ✅ | ✅ | نفس 51 |
| 55 | [ECS native blue/green و linear و canary](scenarios/55-ecs-native-bluegreen-linear-canary.md) | ✅ | ✅ | نفس 51 |
| 56 | [Capacity providers و Fargate Spot](scenarios/56-ecs-capacity-providers-spot.md) | ✅ | ✅ | أرخص |
| 57 | [ECS autoscaling تحت load](scenarios/57-ecs-autoscaling-under-load.md) | ✅ | ✅ | نفس 51 |
| 58 | [ECS deploy بـ GitHub Actions مقابل CodePipeline](scenarios/58-ecs-github-actions-vs-codepipeline.md) | ✅ | ✅ | نفس 51 |

### G. Kubernetes / EKS

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 60 | [Kubernetes محلي على kind (أو على GitHub Actions)](scenarios/60-kubernetes-on-kind.md) | — | ✅ | مجاني |
| 61 | [EKS من الـ Console و eksctl](scenarios/61-eks-console-eksctl.md) | ✅ | ✅ | ~$5.5/يوم |
| 62 | [EKS بـ Terraform](scenarios/62-eks-terraform.md) | — | ✅ | ~$5.5/يوم |
| 63 | [AWS Load Balancer Controller + Ingress + ACM](scenarios/63-eks-load-balancer-controller-ingress.md) | ✅ | ✅ | + ALB |
| 64 | [External Secrets + SSM Parameter Store](scenarios/64-eks-external-secrets.md) | — | ✅ | مجاني |
| 65 | [Helm chart للتطبيق (+ migrate hook)](scenarios/65-helm-chart.md) | — | ✅ | — |
| 66 | [RollingUpdate و Recreate (probes، preStop، PDB)](scenarios/66-k8s-rolling-recreate.md) | — | ✅ | — |
| 67 | [Blue/Green على Kubernetes](scenarios/67-k8s-bluegreen.md) | — | ✅ | — |
| 68 | [Canary بـ Argo Rollouts + analysis](scenarios/68-k8s-canary-argo-rollouts.md) | — | ✅ | — |
| 69 | [GitOps بـ Argo CD](scenarios/69-gitops-argocd.md) | — | ✅ | — |
| 6A | [HPA + Karpenter تحت load](scenarios/6A-hpa-karpenter-under-load.md) | — | ✅ | — |

### H. Observability و SRE

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 70 | [Logging (JSON → CloudWatch Logs Insights، Loki)](scenarios/70-logging.md) | ✅ | ✅ | سنتات |
| 71 | [Metrics و Dashboards (Prometheus، Grafana، CloudWatch)](scenarios/71-metrics-dashboards.md) | ✅ | ✅ | سنتات |
| 72 | [Tracing بـ OpenTelemetry](scenarios/72-tracing-opentelemetry.md) | ✅ | ✅ | سنتات |
| 73 | [SLI/SLO و Error budget و Burn-rate alerts](scenarios/73-slo-error-budget-burn-rate.md) | ✅ | ✅ | سنتات |
| 74 | [Load testing بـ k6 (smoke→soak→breakpoint)](scenarios/74-load-testing-k6.md) | — | ✅ | — |
| 75 | [Chaos engineering بـ AWS FIS + Game day](scenarios/75-chaos-engineering-fis.md) | ✅ | ✅ | سنتات |
| 76 | [Incident response (runbooks، postmortem)](scenarios/76-incident-response.md) | — | — | — |
| 77 | [Backup و Disaster Recovery (RTO/RPO)](scenarios/77-backup-and-dr.md) | ✅ | ✅ | سنتات |

### I. الأمان (DevSecOps)

| # | السيناريو | Console | IaC | التكلفة |
|---|---|:-:|:-:|---|
| 80 | [IAM و OIDC و Least privilege و Session Manager](scenarios/80-iam-oidc-least-privilege.md) | ✅ | ✅ | مجاني |
| 81 | [إدارة الـ Secrets (SSM مقابل Secrets Manager، rotation)](scenarios/81-secrets-management.md) | ✅ | ✅ | سنتات |
| 82 | [Supply chain (Trivy، SBOM، cosign، Dependabot، checkov)](scenarios/82-supply-chain-security.md) | — | ✅ | مجاني |
| 83 | [Edge security (WAF، HTTPS، headers، rate limiting)](scenarios/83-edge-security-waf-https.md) | ✅ | ✅ | ~$8–12/شهر |

### J. الـ IaC بالتفصيل

| # | السيناريو |
|---|---|
| 90 | [Terraform بالتفصيل (modules، state، environments)](scenarios/90-terraform-deep-dive.md) |
| 91 | [Import لموارد الـ Console جوه Terraform + drift](scenarios/91-terraform-import-and-drift.md) |
| 92 | [Terraform في الـ CI (plan على PR، approvals، infracost)](scenarios/92-terraform-in-ci.md) |
| 93 | [Ansible بالتفصيل (roles، vault، dynamic inventory)](scenarios/93-ansible-deep-dive.md) |

### K. الختام

| # | السيناريو |
|---|---|
| 95 | [Database migrations من غير downtime (expand/contract)](scenarios/95-zero-downtime-db-migrations.md) |
| 96 | [جداول المقارنة (الاستراتيجيات، المنصات، أدوات الـ CI)](scenarios/96-comparison-matrices.md) |
| 97 | [التكلفة والمسح](scenarios/97-cost-and-teardown.md) |
| 98 | [الـ Portfolio وأسئلة الـ Interview](scenarios/98-portfolio-and-interview.md) |
| 99 | [Cheat sheets و Troubleshooting](scenarios/99-cheatsheets-and-troubleshooting.md) |

---

## خريطة الملفات في الـ repo

| المسار | فيه إيه |
|---|---|
| [`docker/`](../../docker) · [`docker-compose.yml`](../../docker-compose.yml) · [`docker-compose.prod.yml`](../../docker-compose.prod.yml) | الـ image والـ compose (local / EC2) |
| [`deploy/ec2/`](../../deploy/ec2) | user-data، deploy scripts، backups، وستاك الـ zero-downtime ([`lb/`](../../deploy/ec2/lb)) |
| [`deploy/scripts/`](../../deploy/scripts) | `probe.sh` (قياس الـ downtime)، `with-probe.sh`، `version-split.sh` |
| [`deploy/codebuild/`](../../deploy/codebuild) · [`deploy/ecs/`](../../deploy/ecs) · [`deploy/codedeploy/`](../../deploy/codedeploy) | buildspecs و task definitions و appspecs |
| [`infra/terraform/`](../../infra/terraform) | bootstrap + modules + stacks (20, 35, 36, 40, 50, 60) |
| [`infra/ansible/`](../../infra/ansible) · [`infra/packer/`](../../infra/packer) | configuration management والـ golden AMI |
| [`k8s/`](../../k8s) | kind، plain manifests، Helm chart، Argo Rollouts، Argo CD |
| [`observability/`](../../observability) · [`loadtest/`](../../loadtest) | Prometheus/Grafana/Loki، SLO rules، dashboards، FIS، OTel، k6 |
| [`.github/workflows/`](../../.github/workflows) | CI و lab-integration و k8s-integration و lint و deploy workflows |
| [`app/Http/Controllers/SreLabController.php`](../../app/Http/Controllers/SreLabController.php) · [`config/sre_lab.php`](../../config/sre_lab.php) | الـ SRE endpoints والـ fault injection |

## بناء الـ PDF

```bash
cd docs/devops/pdf
npm ci
node build-pdf.mjs --summary   # → docs/devops/SUMMARY.pdf
node build-pdf.mjs --full      # → docs/devops/HANDBOOK.pdf
```
