# Project Plan — Secure GenAI Inference Gateway

## Concept (in one line)

Build a guarded front door that sits between users and Amazon Bedrock: it checks
who you are, inspects what you send, blocks/redacts anything dangerous, logs
everything, alerts on attacks, and deploys safely through CI/CD.

---

## The idea, in plain words

A powerful AI model is like a very capable employee who will do almost anything
you ask. You don't let strangers walk up and give that employee orders. You put a
security desk in front:

1. **Cognito** checks your ID at the door (authentication).
2. **API Gateway** is the only door in.
3. **Lambda (Python)** is the guard who reads your request and decides what to do.
4. **Bedrock Guardrails** is the filter that strips out attacks, PII, and toxicity.
5. **Bedrock** is the model that actually answers — only after the request is clean.
6. **CloudWatch + S3** write down everything that happened (the logbook).
7. **SNS** raises the alarm when something looks like an attack.
8. **Terraform / GitHub Actions / Checkov** make sure the whole thing is built
   the same way every time, reviewed before it ships, and scanned for mistakes.

---

## Architecture

```
                 +-------------+
   User  ------> |   Cognito   |   login / tokens
                 +------+------+
                        v
                 +-------------+
                 | API Gateway |   the only way in
                 +------+------+
                        v
                 +-------------+      +----------------------+
                 |   Lambda    |----> |  Bedrock Guardrails  |
                 |  (Python)   |      |   +  Amazon Bedrock   |
                 | inspect +   | <----|                      |
                 | orchestrate |      +----------------------+
                 +------+------+
                        |
          +-------------+-------------+
          v             v             v
     +----------+  +----------+  +----------+
     |CloudWatch|  |    S3    |  |   SNS    |
     |  (logs)  |  |  (logs)  |  | (alerts) |
     +----------+  +----------+  +----------+
```

---

## Phases & checklist

### Phase 1 — Foundations & Setup ✅
- [x] Install VS Code, Git (Git Bash as default VS Code terminal), AWS CLI v2
- [x] Enable MFA on root account
- [x] Create IAM user `darsh` (AdministratorAccess) + MFA
- [x] Configure AWS CLI (`us-east-1`, JSON) and verify with `aws sts get-caller-identity`
- [x] Create project folder + Git repo; add `.gitignore` BEFORE first commit
- [x] First commit pushed to private GitHub repo
- [x] Initialize README.md, plan.md, learnings.md

### Phase 2 — Terraform / Infrastructure as Code ✅
- [x] Install Terraform; verify `terraform -version`
- [x] Create `terraform/main.tf` (provider config, AWS provider pinned `~> 6.0`)
- [x] Add Terraform rules to `.gitignore` (ignore tfstate; commit lock file)
- [x] `terraform init` + `terraform plan`
- [x] Provision hardened S3 logs bucket
      (bucket + Block Public Access + AES256 encryption + versioning)
- [x] Provision hardened S3 state bucket (same hardening)
- [x] Add `backend "s3"` block (encrypt + use_lockfile) and migrate state to S3

### Phase 3 — Lambda (Python): the gateway "brain" ✅
- [x] Create `terraform/lambda.tf`
- [x] IAM execution role + trust policy (only `lambda.amazonaws.com` may assume)
- [x] CloudWatch log group (explicit, 14-day retention)
- [x] Least-privilege logging policy (only `CreateLogStream`/`PutLogEvents`, scoped to our log group)
- [x] Write the Python handler (`src/handler.py`) — skeleton "brain" (logs length, not content)
- [x] Declare `hashicorp/archive` provider; `archive_file` to zip code + `aws_lambda_function` resource
- [x] `terraform apply` (4 added); test-invoke returned 200; confirmed logs in CloudWatch

### Phase 4 — Cognito + API Gateway
- [ ] Cognito user pool (authentication)
- [ ] API Gateway in front of Lambda, secured by Cognito

### Phase 5 — Bedrock + Guardrails
- [ ] Connect Lambda to Amazon Bedrock
- [ ] Configure Bedrock Guardrails (PII, prompt injection, toxicity)

### Phase 6 — Observability & alerting
- [ ] CloudWatch logging (metadata + redacted prompts — never raw secrets)
- [ ] SNS alerts on attack patterns

### Phase 7 — CI/CD + security scanning
- [ ] GitHub Actions pipeline (plan/apply, using the S3 remote state)
- [ ] Checkov scanning (fail build on insecure config)
- [ ] OIDC authentication (replace long-lived IAM keys)

---

## Important notes & principles

- **Security first, by default.** Every resource is built private/locked-down;
  safety is written explicitly in code, not left to defaults.
- **Plan before apply, always.** `terraform plan` is a dry run; read it before
  building. Watch the "to destroy" count.
- **Never commit the treasure map.** `terraform.tfstate` can hold secrets — it
  is always git-ignored, and now lives remotely in S3.
- **Pin versions.** Providers are pinned for reproducible, reviewable builds.
- **State is shared memory.** Remote S3 state survives the laptop and lets the
  Phase 7 CI/CD pipeline run Terraform in the cloud.
- **Least privilege later.** Current AdministratorAccess + long-lived keys is a
  solo-learning trade-off; tighten to least-privilege + OIDC before "production".
- **Living docs.** README.md, plan.md, and learnings.md are updated after every
  completed task.
