# Secure GenAI Inference Gateway on AWS

A security checkpoint that sits **between users and an AI model (Amazon Bedrock)**.
It authenticates callers, inspects every prompt for attacks (prompt injection, PII
leakage, toxicity), blocks or redacts dangerous content with Bedrock Guardrails,
logs every interaction, alerts on attacks, and ships through a CI/CD pipeline with
automated security scanning.

> Built from scratch as a structured, phase-by-phase learning project. Everything
> is defined as code (Terraform) and version-controlled.

---

## Why this exists

Letting users talk directly to a powerful AI model is risky: prompts can carry
attacks, leak secrets, or pull the model off-task. This gateway is the guarded
front door — nothing reaches the model without passing through authentication,
inspection, and filtering first, and nothing happens without being logged.

---

## Architecture (target)

```
                 +-------------+
   User  ------> |   Cognito   |   who are you?  (login / tokens)
                 +------+------+
                        v
                 +-------------+
                 | API Gateway |   the front door  (the only way in)
                 +------+------+
                        v
                 +-------------+      +----------------------+
                 |   Lambda    |----> |  Bedrock Guardrails  |  filter:
                 |  (Python)   |      |   +  Amazon Bedrock   |  PII / injection /
                 |  the brain  | <----|      (the model)     |  toxicity
                 +------+------+      +----------------------+
                        |
          +-------------+-------------+
          v             v             v
     +----------+  +----------+  +----------+
     |CloudWatch|  |    S3    |  |   SNS    |
     |  (logs)  |  |  (logs)  |  | (alerts) |
     +----------+  +----------+  +----------+
```

---

## Tech stack

| Area | Service / Tool |
|---|---|
| Authentication | Amazon Cognito |
| API entry point | Amazon API Gateway |
| Application logic | AWS Lambda (Python) |
| AI model | Amazon Bedrock |
| Content safety | Amazon Bedrock Guardrails |
| Logging / metrics | Amazon CloudWatch |
| Log storage | Amazon S3 |
| Alerting | Amazon SNS |
| Infrastructure as Code | Terraform |
| CI/CD | GitHub Actions |
| Security scanning | Checkov |

---

## Project structure

```
secure-genai-gateway/
├── .gitignore              # guards secrets/state from Git
├── README.md               # this file
├── plan.md                 # full plan, architecture, phases, checklist
├── learnings.md            # per-phase notes, memory tricks, Q&A
├── src/
│   └── handler.py         # Lambda handler (the gateway "brain")
└── terraform/
    ├── main.tf            # provider + backend config + S3 buckets
    ├── lambda.tf          # Lambda function + IAM role + log group
    ├── cognito.tf         # Cognito user pool + app client (authentication)
    ├── apigateway.tf      # HTTP API + integration + JWT authorizer + route + stage
    ├── bedrock.tf         # Guardrail (PII/injection/toxicity) + version + Lambda Bedrock IAM
    ├── alerting.tf        # SNS topic + email sub + metric filter + alarm (attack alerts)
    ├── oidc.tf            # GitHub OIDC provider + read-only CI role (no stored keys)
    ├── outputs.tf         # api_base_url, user_pool_id, app_client_id
    ├── .terraform.lock.hcl # committed: exact provider versions + checksums
    ├── .terraform/         # IGNORED: downloaded provider plugins
    └── terraform.tfstate   # IGNORED local leftover (real state lives in S3)
```

State is stored **remotely in S3** (an encrypted, versioned, locked bucket), not on
the local disk. See "Remote state" below.

---

## Setup / prerequisites

- An AWS account with **MFA** enabled on root and on an IAM user.
- A dedicated IAM user (here: `darsh`) used for day-to-day work — **never** root.
- **AWS CLI v2** installed and configured (`aws configure`), region `us-east-1`.
- **Terraform** installed (verify with `terraform -version`).
- **Git** + a GitHub account (this repo is **private**).
- Editor: **VS Code**, terminal: **Git Bash** (Linux-style shell on Windows).

Verify your AWS connection:

```bash
aws sts get-caller-identity   # should return your IAM user ARN, not root
```

Provision infrastructure:

```bash
cd terraform
terraform init      # download providers, configure the S3 backend
terraform plan      # dry run — shows what WOULD change
terraform apply     # build for real (type 'yes' to confirm)
```

---

## Remote state

Terraform's state (its memory of what it built) is stored in a **dedicated,
hardened S3 bucket** (`secure-genai-gateway-tfstate-...`), configured via a
`backend "s3"` block in `main.tf` with:

- `encrypt = true` — state encrypted at rest
- `use_lockfile = true` — native S3 locking so two runs can't collide

This keeps the state safe, durable, and shareable — and is required for the
Phase 7 CI/CD pipeline, which runs Terraform in the cloud (not on the laptop).

---

## Security notes

- **Never committed:** `terraform.tfstate`, `*.tfvars`, `.terraform/` — state can
  contain secrets in plaintext.
- **Committed on purpose:** `.terraform.lock.hcl` — pins exact provider versions
  and checksums for reproducible, tamper-checked builds.
- All resources are built **private and locked-down by default**; both S3 buckets
  have Block Public Access, encryption at rest, and versioning.
- **CI/CD auth uses OIDC, not stored keys** (`oidc.tf`): GitHub Actions assumes a
  short-lived role via web identity — no AWS access keys are stored in GitHub. The
  trust policy is pinned to this exact repo on `main`, and the role is **read-only**
  (`terraform plan` only); `apply` is still run manually. Long-lived keys remain only
  for local developer use.
- This repo is being made **public** (linked from a resume). History + content were
  audited first — no secrets, state, tfvars, keys, or hardcoded account ID ever
  committed. Going public makes "never commit a secret" non-negotiable (a public repo
  exposes the entire git history).

---

## Status

**Phase 6 (Observability & alerting — the logbook + the alarm bell) — COMPLETE.**
The handler now writes **structured, redacted JSON logs** — one line per request with
metadata only (`prompt_length`, never the prompt text), tagging blocked attacks with
`{"event": "GUARDRAIL_BLOCK"}`. A CloudWatch **metric filter** (`alerting.tf`) counts
those lines into a `GuardrailBlocks` metric, and a CloudWatch **alarm** (any block in a
60-second window) notifies an **SNS topic** that emails the operator. Detection lives in
infrastructure, not app code, so alerting can be re-tuned without redeploying the Lambda.
Verified end-to-end: a normal prompt is answered with **no alert**, while a prompt-injection
attempt is **blocked** and triggers an **alert email** within ~1–3 minutes; logs confirmed
to contain no raw prompt text.

**Phase 7 (CI/CD + security scanning) — IN PROGRESS.** _7a — OIDC authentication:_ **COMPLETE.**
`oidc.tf` now defines a GitHub OIDC identity provider and a **read-only** IAM role that
GitHub Actions assumes via short-lived web-identity tokens — **no AWS access keys are
stored in GitHub**. The trust policy is pinned to this exact repo on `main`
(`sts:AssumeRoleWithWebIdentity` + `aud`/`sub` conditions), so forks cannot assume it;
permissions are AWS-managed `ReadOnlyAccess` plus scoped state-bucket access for the plan
lock. Verified via `terraform apply` (4 added) and `aws iam get-role`. **Next: 7b — Checkov
scanning on `terraform/`, then 7c — the GitHub Actions workflow that assumes this role to
run `terraform plan`.**

_Known trade-offs (flagged for the Phase 7 hardening pass):_ the user pool has MFA
`OFF` and uses `USER_PASSWORD_AUTH` for easy CLI testing; content filters are set to
`HIGH` (may cause false positives — tune per use-case); the SNS topic is **not yet
KMS-encrypted** (alerts are metadata-only, and the free AWS-managed key breaks alarm
delivery — needs a customer-managed key); the alarm logs *that* a block happened, not yet
*which category* (guardrail `trace` is a deferred Phase 6.5 polish).

See `plan.md` for the full phase checklist and `learnings.md` for detailed notes.
