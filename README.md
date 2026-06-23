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
└── terraform/
    ├── main.tf             # provider + backend config + resources
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

**Phase 3 (Lambda — the gateway's brain) — COMPLETE.**
Lambda `secure-genai-gateway-handler` (Python 3.13) is live, deployed via Terraform
(`lambda.tf` + `src/handler.py`). It runs under a least-privilege IAM role whose
only permission is writing to its own CloudWatch log group (14-day retention). The
skeleton handler acknowledges requests and logs prompt *length*, never content.
Test-invoke returns `200`; logs confirmed in CloudWatch.
**Next: Phase 4 — Cognito + API Gateway (the ID check and the only door in).**

See `plan.md` for the full phase checklist and `learnings.md` for detailed notes.
