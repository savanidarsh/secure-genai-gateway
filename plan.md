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

### Phase 6 — Observability & alerting ✅
- [x] Structured, redacted logging in `src/handler.py` — `_log()` helper emits one
      JSON line per request, metadata only (`prompt_length`, never the prompt); block
      path emits `{"event": "GUARDRAIL_BLOCK", ...}` (the hook for the metric filter)
- [x] SNS topic `secure-genai-gateway-alerts` + email subscription (`alerting.tf`);
      confirmed the subscription via the AWS email link
- [x] CloudWatch Logs metric filter — JSON pattern `{ $.event = "GUARDRAIL_BLOCK" }`
      → `GuardrailBlocks` metric (namespace `SecureGenAIGateway`, `default_value = "0"`)
- [x] CloudWatch alarm — `Sum` over 60s, 1 evaluation period, `> 0` → SNS;
      `treat_missing_data = "notBreaching"`
- [x] `apply` (4 added, 1 changed, 0 destroyed); tested: normal prompt → no alert;
      injection → blocked → **alert email received**; logs confirmed redacted
- [ ] (deferred → Phase 7) KMS-encrypt the SNS topic with a customer-managed key
      (AWS-managed `alias/aws/sns` breaks CloudWatch alarm delivery)
- [ ] (deferred → Phase 6.5) capture blocked category via guardrail `trace`

### Phase 7 — CI/CD + security scanning (in progress)

**Context:** repo will be made **public** (resume/recruiters) → trust policy
scoped tightly; nothing secret ever committed. Decided: pipeline role is
**read-only** (runs `terraform plan` only); human runs `apply` manually. Most
secure least-privilege story; revisit a gated apply job later if wanted.

**7a — OIDC authentication (replace long-lived IAM keys) ✅**
- [x] `terraform/oidc.tf` — `aws_iam_openid_connect_provider.github`
      (url `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`,
      **no** thumbprint_list — AWS provider v5+ validates GitHub's CA itself;
      hardcoded thumbprints rot)
- [x] `aws_iam_role.github_actions` — trust policy:
      `sts:AssumeRoleWithWebIdentity`, Principal = Federated OIDC provider,
      Condition StringEquals `:aud = sts.amazonaws.com` AND
      `:sub = repo:savanidarsh/secure-genai-gateway:ref:refs/heads/main`
      (exact match, no wildcard → forks can't assume it)
- [x] Permissions: AWS-managed `ReadOnlyAccess` attachment + scoped inline
      `tfstate-access` (Get/Put/Delete on state bucket objects for the plan
      lock; ListBucket) — nothing else writable
- [x] `apply` (4 added, 0 changed, 0 destroyed); verified trust policy via
      `aws iam get-role` (Action/aud/sub all correct)

**7b — Checkov scanning (fail build on insecure config)**
- [ ] Run Checkov locally on `terraform/`; review + triage findings
- [ ] Wire Checkov into the pipeline (fail on insecure config)

**7c — GitHub Actions pipeline (plan on the S3 remote state)**
- [ ] `.github/workflows/` — workflow assuming the OIDC role (no stored keys)
- [ ] `terraform plan` on push/PR; Checkov gate
- [ ] (optional later) gated apply job via GitHub Environment + approval

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
