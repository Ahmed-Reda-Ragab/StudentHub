# NN — عنوان السيناريو

> **الهدف في سطر:** هتتعلم إيه وهتخرج بإيه.
> **المستوى:** Beginner / Intermediate / Advanced · **الوقت:** ~X ساعة · **التكلفة التقريبية:** $X/يوم (أو مجاني)
> **بيعتمد على:** [NN — اسم](NN-slug.md) · **الملفات في الـ repo:** [`path/to/file`](../../../path/to/file)

## 1) الفكرة (Concepts)

شرح مختصر للمفهوم: إيه هو، وليه موجود، وإيه البدائل، وإمتى تختاره.

| المصطلح | المعنى |
|---|---|
| Term | شرح قصير |

## 2) المعمارية (Architecture)

```text
ASCII diagram
```

## 3) المتطلبات (Prerequisites)

- [ ] حاجة لازم تكون جاهزة
- الأدوات: `aws` · `terraform` · ...

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **Service → Page** → اعمل كذا (القيم بالظبط: ...).
2. ...

> 💡 ليه بنعمل الخطوة دي؟

## 5) الطريقة التانية: Infrastructure as Code (Terraform / Ansible)

```bash
cd infra/terraform/stacks/NN-...
terraform init -backend-config=../../backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

شرح أهم الـ resources والـ variables.

## 6) الـ Deploy

```bash
# الأوامر بالترتيب
```

## 7) التحقق (Verify)

```bash
curl -s http://<HOST>/ready
deploy/scripts/probe.sh http://<HOST>/ready 120 0.2
```

المفروض تشوف: ...

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Bad release | `SRE_FAULT_ERROR_RATE=0.5` | ... |

## 9) الرجوع (Rollback)

```bash
```

## 10) المسح (Teardown) ⚠️

```bash
terraform destroy
```

تأكد إن مفيش حاجة لسه شغالة: ...

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|

## 12) أسئلة Interview

<details><summary>سؤال؟</summary>

إجابة مختصرة بمستوى Senior.

</details>

## 13) Checklist

- [ ] عملتها من الـ Console
- [ ] عملتها بالـ IaC
- [ ] جرّبت الـ break-it والـ rollback
- [ ] عملت teardown
