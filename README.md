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
- Long-lived IAM access keys are a temporary, solo-learning trade-off; the plan
  is to move to short-lived credentials (OIDC) in the CI/CD phase.

---

## Status

**Phase 5 (Bedrock + Guardrails — the model, behind a safety filter) — COMPLETE.**
The Lambda now calls **Claude Haiku 4.5** on **Amazon Bedrock** via the Converse API,
using the `us.` cross-region inference profile. Every call runs through an **Amazon
Bedrock Guardrail** (`bedrock.tf`): content filters for hate/insults/sexual/violence/
misconduct and **prompt-injection** detection, plus a **PII filter** that anonymizes
emails/phones and blocks SSNs and card numbers. The handler parses the prompt from the
HTTP body, attaches the guardrail to the model call, and reports `blocked` when the
guardrail intervenes. Lambda permissions are least-privilege — scoped to this one model
(in each cross-region destination) and this one guardrail, never `*`. Verified
end-to-end through `POST /chat`: a normal prompt is **answered**, a prompt-injection
attempt is **blocked**, and a prompt containing an SSN is **blocked**.
**Next: Phase 6 — Observability & alerting (CloudWatch logging of metadata + the
guardrail trace, SNS alerts on attack patterns).**

_Known trade-offs (flagged for the Phase 6 hardening pass):_ the user pool has MFA
`OFF` and uses `USER_PASSWORD_AUTH` for easy CLI testing; content filters are set to
`HIGH` (may cause false positives — tune per use-case); guardrail PII actions
currently cover a starter set of entity types.

See `plan.md` for the full phase checklist and `learnings.md` for detailed notes.
