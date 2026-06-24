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

### Phase 4 — Cognito + API Gateway ✅
- [x] Cognito user pool (`cognito.tf`) — email login, strong password policy, email recovery
- [x] Cognito app client (`generate_secret = false`, USER_PASSWORD + REFRESH auth flows)
- [x] HTTP API (API Gateway v2) — `apigatewayv2_api`, protocol `HTTP`
- [x] Lambda proxy integration (`AWS_PROXY`, payload format `2.0`)
- [x] `aws_lambda_permission` — let API Gateway invoke the Lambda
- [x] JWT authorizer pointed at Cognito (audience = app client, issuer = pool URL)
- [x] Protected route `POST /chat` (`authorization_type = "JWT"`)
- [x] `$default` stage with `auto_deploy = true`
- [x] Outputs: `api_base_url`, `user_pool_id`, `app_client_id`
- [x] `apply` (8 added, 0 destroyed); tested: no token → **401**, valid ID token → **200**
- [ ] (deferred) MFA on the user pool — currently OFF; revisit in Phase 6 hardening

### Phase 5 — Bedrock + Guardrails ✅
- [x] Confirm Bedrock model access (Console: legacy "Model access" page retired;
      serverless models auto-enable on first use, IAM is now the real gate)
- [x] Pick model: **Claude Haiku 4.5** (cheapest); copy exact Model ID from console
- [x] Note model is **cross-region inference** → must use the `us.` inference
      profile ID (`us.anthropic.claude-haiku-4-5-20251001-v1:0`), not the bare ID
- [x] Create `terraform/bedrock.tf` — `aws_bedrock_guardrail`:
      content filters HATE/INSULTS/SEXUAL/VIOLENCE/MISCONDUCT (in+out HIGH) and
      PROMPT_ATTACK (in HIGH, out NONE); PII filter (EMAIL/PHONE → ANONYMIZE,
      SSN/CREDIT_CARD → BLOCK)
- [x] Add `aws_bedrock_guardrail_version` (frozen, numbered snapshot to pin)
- [x] Extend Lambda IAM (`aws_iam_role_policy.lambda_bedrock`): InvokeModel/Converse/
      GetInferenceProfile scoped to the profile ARN **+ foundation-model ARN in each
      cross-region destination** (us-east-1/-2, us-west-2); ApplyGuardrail on our
      guardrail ARN. No `Resource = "*"`.
- [x] Rewrite `src/handler.py`: parse prompt from HTTP `body`, call `bedrock.converse`
      with `guardrailConfig`, return answer, detect `stopReason == guardrail_intervened`
- [x] Add `environment` vars to Lambda (MODEL_ID, GUARDRAIL_ID, GUARDRAIL_VERSION);
      bump timeout 10 → 30
- [x] `apply` (hit a provider "inconsistent final plan" bug on first env block →
      re-ran apply, succeeded). Tested end-to-end via `POST /chat` with a Cognito
      token: normal prompt → **answered**; injection → **blocked**; SSN → **blocked**

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
