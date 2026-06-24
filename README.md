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

**Phase 4 (Cognito + API Gateway — the ID check and the only door in) — COMPLETE.**
Users authenticate against an **Amazon Cognito** user pool (`cognito.tf`) and receive
JWT tokens via a public app client. An **HTTP API** (API Gateway v2, `apigateway.tf`)
is the single entry point, wired to the Lambda through a proxy integration. The
`POST /chat` route is protected by a **JWT authorizer** that validates each token's
issuer (our pool) and audience (our app client). Verified end-to-end: a request with
**no token returns `401`**, and a request carrying a valid Cognito ID token returns
`200` and reaches the Lambda. Live URL printed via the `api_base_url` output.
**Next: Phase 5 — Bedrock + Guardrails (connect the model; parse the prompt from the
request body; add PII / injection / toxicity filtering).**

_Known trade-off:_ the user pool has MFA `OFF` and uses `USER_PASSWORD_AUTH` for easy
CLI testing — both are flagged for the Phase 6 hardening pass.

See `plan.md` for the full phase checklist and `learnings.md` for detailed notes.
