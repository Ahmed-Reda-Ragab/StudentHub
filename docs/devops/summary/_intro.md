# StudentHub DevOps / SRE Lab — الملخص الشامل

> الملخص ده بيجمع **كل السيناريوهات** في مكان واحد عشان تراجع بسرعة: الهدف، أهم الأوامر، إزاي تتأكد، والـ gotchas، والتكلفة.
> التفاصيل الكاملة لكل سيناريو في ملفه في `docs/devops/scenarios/`. الـ HANDBOOK.pdf فيه كل السيناريوهات كاملة.

## المعمل في سطور

مشروع Laravel حقيقي (Students Subscriptions) بنستخدمه معمل لكل طرق الـ deploy على AWS. كل سيناريو بيتعمل **مرتين**: مرة من الـ **Console** ومرة بـ **Terraform + Ansible**. الـ CI/CD موجود على **GitHub Actions** وعلى **CodeBuild/CodePipeline/CodeDeploy**، ومعاه كل أنواع الـ **zero-downtime deployment**، ومفاهيم **SRE** بتتقاس بجد.

```text
A. الأساسيات (01–03)
   │
B. Containers (10–12) ──► C. EC2 سيرفر واحد (20–27) ──► D. CI/CD (30–37)
                                   │                          │
                                   ▼                          ▼
                        E. EC2 على نطاق أكبر (40–49) ◄────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            ▼                      ▼                      ▼
     F. ECS (50–58)      G. Kubernetes/EKS (60–6A)   H. Observability & SRE (70–77)
            └──────────────────────┼──────────────────────┘
                                   ▼
        I. Security (80–83) · J. IaC deep dives (90–93) · K. Wrap-up (95–99)
```

## إزاي تستخدم الملخص

1. ابدأ بـ **01** (الأدوات) و **02/03** (الحساب والجهاز).
2. كل كارت فيه أهم أوامر السيناريو. التفاصيل والـ Console click-path في ملف السيناريو.
3. **مفيش Docker على جهازك؟** اعمل push على branch، وتابع:
   - `ci.yml`
   - `lab-integration.yml`: compose و k6 والـ zero-downtime scripts
   - `k8s-integration.yml`: kind و Helm و Argo Rollouts
   - `lint-infra.yml`
4. أي سيناريو فيه موارد AWS: **Teardown فوراً** بعد ما تخلص. راجع كارت **97**.

## مرجع سريع: الـ endpoints والـ SLOs

| Endpoint | الاستخدام |
|---|---|
| `GET /up` | Liveness (من غير DB) |
| `GET /ready` | Readiness (DB ping)، بيرجّع `version` و `color` |
| `GET /metrics` | Prometheus (`METRICS_ENABLED`، و `METRICS_TOKEN` اختياري) |
| `/sre-lab/{ping,version,latency,error,cpu,memory,db,db/heavy,unready,ready}` | load/chaos. بيرجّع 404 لو `SRE_LAB_ENABLED` مش `true`، والـ header `X-Lab-Token` مطلوب لو الـ token متحدد |

| Bad release (env) | مين يكشفه |
|---|---|
| `SRE_FAULT_ERROR_RATE=0.5` | canary analysis / burn-rate alerts |
| `SRE_FAULT_LATENCY_MS=800` | latency SLO |
| `SRE_FAULT_UNHEALTHY=true` | health checks → rollback |
| `SRE_FAULT_BOOT_FAIL=true` | circuit breaker / CrashLoopBackOff |

**الـ SLOs:**

- **Availability:** 99.5% على 30 يوم. الـ error budget حوالي 3 ساعات و36 دقيقة.
- **Latency:** 95% من الـ requests أقل من 300ms، والـ p99 أقل من 1s.

**الـ Burn-rate alerts:**

| السرعة | النوافذ | الإجراء |
|---|---|---|
| 14.4× | 1h و 5m | page |
| 6× | 6h و 30m | page |
| 1× | 3d و 6h | ticket |
