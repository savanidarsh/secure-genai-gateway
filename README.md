# Secure GenAI Inference Gateway on AWS

A security checkpoint that sits between users and an AI model (Amazon Bedrock).
It authenticates users, inspects every prompt for attacks (prompt injection, PII
leakage, toxicity), blocks or redacts dangerous content, logs every interaction,
alerts on attacks, and deploys through a CI/CD pipeline with security scanning.

> **Status:** 🚧 In progress — Phase 1 (Foundations & Setup). This is a learning
> project built from scratch, so this README evolves as the project does.

---

## Why this exists (the problem)

Letting users talk to an AI model directly is risky. People can try to trick the
model (*prompt injection*), leak private data (*PII*), or push abusive content
(*toxicity*). This project puts a guarded "front door" in front of the model so
every request is checked on the way in **and** on the way out.

**One-line analogy:** it's airport security for messages going to an AI.

---

## Architecture (request flow)

```
        USER
         │  prompt
         ▼
   [ Amazon Cognito ]    authenticate — is this a known, logged-in user?
         │
         ▼
   [ API Gateway ]       the public front door (HTTPS endpoint)
         │
         ▼
   [ Lambda (Python) ]   the "guard": orchestrates checks + calls the model
         │  ├──► [ Bedrock Guardrails ]  scan prompt: injection / PII / toxicity
         │  └──► [ Amazon Bedrock ]      generate answer (only if prompt is clean)
         ▼
   [ Lambda (Python) ]   scan the ANSWER too (Guardrails) before returning
         │
         ▼
        USER (clean response)

   Cross-cutting:  CloudWatch (logs + metrics)   SNS (attack alerts)   S3 (log/artifact storage)
```

---

## Tech stack

| Layer            | Service / Tool        | Role in plain English                          |
|------------------|-----------------------|------------------------------------------------|
| Auth             | Amazon Cognito        | Checks user IDs (login)                         |
| Entry point      | API Gateway           | The public front door                           |
| Compute          | AWS Lambda (Python)    | The guard that runs the checks                  |
| AI model         | Amazon Bedrock        | The AI brain that answers                       |
| Content safety   | Bedrock Guardrails    | Blocks/redacts attacks, PII, toxicity           |
| Logging/metrics  | Amazon CloudWatch     | Security cameras + logbook                      |
| Alerts           | Amazon SNS            | Pager that messages the team on attacks         |
| Storage          | Amazon S3             | Stores logs and build artifacts                 |
| Infra as Code    | Terraform             | Blueprint that builds all of the above          |
| CI/CD            | GitHub Actions        | Auto-builds/tests when the blueprint changes    |
| Security scan    | Checkov               | Inspects the blueprint for misconfigurations    |

---

## Repository structure (planned)

```
secure-genai-gateway/
├── README.md
├── plan.md
├── learnings.md
├── .gitignore
├── terraform/          # infrastructure as code (added Phase 2)
├── src/                # Lambda Python source (added Phase 4)
└── .github/workflows/  # CI/CD pipelines (added Phase 7)
```

---

## Prerequisites

- An AWS account (✅ available)
- VS Code, Git (with Git Bash), AWS CLI installed (✅ done)
- Terraform (added in Phase 2)
- A GitHub account

---

## Setup (high level — see `plan.md` for the full step list)

1. Install tooling (VS Code, Git, AWS CLI).
2. Secure the AWS account (root MFA, least-privilege IAM user) and configure the CLI.
3. Create the project folder + `.gitignore`, initialise Git, push to GitHub.
4. Build infrastructure phase by phase with Terraform.

---

## Security notes (read before your first commit)

Some files must **never** be committed to Git/GitHub:

| Never commit            | Why                                                        |
|-------------------------|------------------------------------------------------------|
| `.env` / secrets files  | Hold API keys/passwords — leak = account takeover          |
| AWS credentials         | Leaked keys are scraped by bots within minutes             |
| `*.tfstate`             | Terraform state can contain secrets and resource details    |
| `.terraform/`           | Local provider/cache files, not source                     |

These are blocked via `.gitignore` (created in Phase 1, **before** the first commit).

---

## Cost note

This uses pay-as-you-go AWS services. Most are cheap or free-tier while learning,
but **resources are torn down in the final phase** to avoid ongoing charges.

---

*This is a learning project. The goal is to understand both the technology and how
it is actually built, not just to ship it.*
