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
                 ┌─────────────┐
   User  ──────► │   Cognito   │   who are you?  (login / tokens)
                 └──────┬──────┘
                        ▼
                 ┌─────────────┐
                 │ API Gateway │   the front door  (the only way in)
                 └──────┬──────┘
                        ▼
                 ┌─────────────┐      ┌─────────────────────┐
                 │   Lambda    │────► │  Bedrock Guardrails  │  filter:
                 │  (Python)   │      │   +  Amazon Bedrock  │  PII / injection /
                 │ the "brain" │ ◄────│      (the model)     │  toxicity
                 └──────┬──────┘      └─────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │CloudWatch│  │    S3    │  │   SNS    │
     │  (logs)  │  │  (logs)  │  │ (alerts) │
     └──────────┘  └──────────┘  └──────────┘
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
    ├── main.tf             # provider config + resources
    ├── .terraform.lock.hcl # committed: exact provider versions + checksums
    └── .terraform/         # IGNORED: downloaded provider plugins
    └── terraform.tfstate   # IGNORED: state (can contain secrets)
```

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
terraform init      # download providers, create lock file
terraform plan      # dry run — shows what WOULD change
terraform apply     # build for real (type 'yes' to confirm)
```

---

## Security notes

- **Never committed:** `terraform.tfstate`, `*.tfvars`, `.terraform/` — state can
  contain secrets in plaintext.
- **Committed on purpose:** `.terraform.lock.hcl` — pins exact provider versions
  and checksums for reproducible, tamper-checked builds.
- All resources are built **private and locked-down by default**; the S3 log
  bucket has Block Public Access, encryption at rest, and versioning.
- Long-lived IAM access keys are a temporary, solo-learning trade-off; the plan
  is to move to short-lived credentials (OIDC) in the CI/CD phase.

---

## Status

**Phase 2 (Terraform / IaC) — in progress.**
Provider configured; first resource live: a fully hardened S3 logs bucket
(private + encrypted + versioned). Next: move Terraform state to a secure
remote backend, then begin Phase 3 (Lambda).

See `plan.md` for the full phase checklist and `learnings.md` for detailed notes.
