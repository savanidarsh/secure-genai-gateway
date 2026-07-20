# Secure GenAI Inference Gateway on AWS

A security checkpoint that sits **between users and an AI model (Amazon Bedrock)**. It authenticates every caller, inspects each prompt for attacks (prompt injection, PII leakage, toxicity), blocks or redacts dangerous content with Bedrock Guardrails, logs every interaction, alerts on suspicious activity, and ships through a CI/CD pipeline with automated security scanning.

Everything is defined as code with Terraform and deployed through GitHub Actions using short-lived OIDC credentials — no long-lived AWS keys are stored anywhere.

---

## Why this exists

Letting users talk directly to a powerful language model is risky: prompts can carry injection attacks, exfiltrate secrets, or pull the model off-task. This gateway is the guarded front door — nothing reaches the model without passing authentication, inspection, and content filtering first, and nothing happens without being logged and monitored.

---

## Architecture

```
                 +-------------+
   User  ------> |   Cognito   |   authentication (login / JWT tokens)
                 +------+------+
                        v
                 +-------------+
                 | API Gateway |   the only entry point
                 +------+------+
                        v
                 +-------------+      +----------------------+
                 |   Lambda    |----> |  Bedrock Guardrails  |  filter:
                 |  (Python)   |      |   +  Amazon Bedrock   |  PII / injection /
                 |  gateway    | <----|      (the model)     |  toxicity
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

## Features

- **Authentication at the edge** — every request must carry a valid Cognito-issued JWT; unauthenticated calls are rejected with `401`.
- **Prompt inspection & content safety** — Bedrock Guardrails screen each prompt and response for prompt injection, PII, and toxicity, blocking or redacting as configured.
- **Full audit trail** — structured, redacted logs of every interaction in CloudWatch and S3.
- **Attack alerting** — a CloudWatch metric filter and alarm fire an SNS email notification when a guardrail block occurs.
- **Cost guardrails** — API Gateway throttling, a token-usage alarm, and an account-level AWS Budget act as circuit breakers.
- **Infrastructure as Code** — the entire stack is reproducible from Terraform.
- **Secure CI/CD** — GitHub Actions authenticates to AWS via OIDC (no stored keys) and gates every change behind a Checkov security scan.

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
| Cost controls | AWS Budgets + API Gateway throttling |
| Infrastructure as Code | Terraform |
| CI/CD | GitHub Actions |
| Security scanning | Checkov |

---

## Project structure

```
secure-genai-gateway/
├── .gitignore              # guards secrets/state from Git
├── README.md
├── .github/
│   └── workflows/
│       └── terraform-ci.yml   # OIDC auth + Checkov gate + terraform plan
├── src/
│   └── handler.py             # Lambda gateway handler
└── terraform/
    ├── main.tf                # provider + S3 backend + hardened log buckets
    ├── lambda.tf              # Lambda function + least-privilege IAM role + log group
    ├── cognito.tf             # Cognito user pool + app client
    ├── apigateway.tf          # HTTP API + integration + JWT authorizer + route + stage
    ├── bedrock.tf             # Guardrail (PII/injection/toxicity) + Lambda Bedrock IAM
    ├── alerting.tf            # SNS topic + subscription + metric filter + alarm
    ├── budgets.tf             # account-level AWS Budget cost circuit-breaker
    ├── oidc.tf                # GitHub OIDC provider + read-only CI role
    ├── outputs.tf             # api_base_url, user_pool_id, app_client_id
    ├── variables.tf           # input variables (region, alert email, model, etc.)
    └── .terraform.lock.hcl    # pinned provider versions + checksums
```

Terraform state is stored **remotely in S3** (an encrypted, versioned, locked bucket), never on the local disk — see [Remote state](#remote-state).

---

## Setup / prerequisites

- An AWS account with **MFA** enabled, and a dedicated IAM user (never the root account) for day-to-day work.
- **AWS CLI v2** installed and configured (`aws configure`), region `us-east-1`.
- **Terraform** installed (`terraform -version`).
- **Git** and a GitHub account.

Verify your AWS connection:

```bash
aws sts get-caller-identity   # should return your IAM user ARN, not root
```

Provision the infrastructure:

```bash
cd terraform
terraform init      # download providers, configure the S3 backend
terraform plan      # dry run — shows what would change
terraform apply     # build for real (type 'yes' to confirm)
```

The alert email address and other environment-specific values are supplied as Terraform variables (see `variables.tf`) rather than hardcoded, so the stack can be deployed to any account.

---

## Remote state

Terraform's state (its record of what it built) lives in a **dedicated, hardened S3 bucket**, configured via a `backend "s3"` block in `main.tf` with:

- `encrypt = true` — state encrypted at rest
- `use_lockfile = true` — native S3 locking so two runs can't collide

This keeps state safe, durable, and usable by the CI/CD pipeline, which runs Terraform in the cloud rather than on a laptop.

---

## Design decisions

A few choices worth calling out, and the reasoning behind them:

**OIDC federation instead of stored AWS keys.** GitHub Actions authenticates to AWS by exchanging a short-lived OpenID Connect token for temporary credentials, so there are no long-lived access keys sitting in GitHub secrets to leak or rotate. The trust policy is pinned to this repository on the `main` branch, so no other repo or branch can assume the role.

**A read-only CI role; `apply` stays human.** The pipeline can run `terraform plan` but nothing more — its role is `ReadOnlyAccess` plus a couple of narrowly-scoped state-bucket permissions. Applying changes is always a deliberate human action, so a compromised or misconfigured pipeline can't mutate live infrastructure.

**Remote, encrypted, locked Terraform state.** State lives in a dedicated S3 bucket with encryption at rest, versioning, and native S3 locking, rather than on a developer's laptop. That makes it durable, recoverable, safe for CI to use, and immune to corruption from two runs colliding.

**Content safety as its own layer.** Prompt and response inspection (PII, prompt injection, toxicity) is enforced by Bedrock Guardrails, decoupled from the model itself — so safety policy is versioned and can change without touching application code.

**Metadata-only logging.** Logs capture request structure, outcomes, and token counts — never the prompt text — so the audit trail can't itself become a source of data leakage. Log groups are retained for a year for forensic history.

**Least privilege everywhere.** Every IAM role (Lambda execution, CI) is granted only the specific actions and resources it needs, scoped by ARN, rather than broad managed policies.

**Defense in depth on cost.** API Gateway throttling, reserved Lambda concurrency, a token-usage alarm, and an account-level AWS Budget together cap both abuse and runaway spend — a security concern as much as a financial one.

---

## Security notes

- **Never committed:** `terraform.tfstate`, `*.tfvars`, `.terraform/` — state can contain sensitive values in plaintext. These are enforced by `.gitignore`.
- **Committed on purpose:** `.terraform.lock.hcl` — pins exact provider versions and checksums for reproducible, tamper-checked builds.
- All resources are **private and locked-down by default**: both S3 buckets have Block Public Access, encryption at rest, and versioning enabled.
- **CI/CD uses OIDC, not stored keys** (`oidc.tf`): GitHub Actions assumes a short-lived role via web identity, so no AWS access keys live in GitHub. The trust policy is pinned to this repository on `main`, and the CI role is **read-only** (`terraform plan` only) — `apply` is always run deliberately by a human.
- Every change is scanned by **Checkov** in CI before it can be merged.
