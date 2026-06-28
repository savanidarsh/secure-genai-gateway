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

**7b — Checkov scanning ✅ (local; pipeline gate is 7c)**
- [x] Installed Checkov (pip; Windows PATH fix → added Scripts dir to `~/.bashrc`)
- [x] First scan: **70 passed / 20 failed / 0 parsing errors** on `terraform/`
- [x] Triaged all 20 (approach: balanced — fix cheap high-value, accept the rest
      with inline `#checkov:skip=ID:reason`):
      - **Fixed:** Lambda `reserved_concurrent_executions = 10` (CKV_AWS_115,
        flood/cost cap); log retention 14→365 (CKV_AWS_338); API Gateway access
        logging → new log group (CKV_AWS_76); state-bucket access logging → logs
        bucket + bucket policy granting `logging.s3.amazonaws.com` (CKV_AWS_18)
      - **Skipped w/ reason (17):** DLQ (CKV_AWS_116 — sync invoke), VPC
        (CKV_AWS_117 — no private deps), env-var/log/S3 KMS (CKV_AWS_173/158/145 —
        already AES256 at rest, non-secret), code-signing (CKV_AWS_272), X-Ray
        (CKV_AWS_50 — avoid widening IAM), S3 replication (CKV_AWS_144), lifecycle
        (CKV2_AWS_61), event-notifs (CKV2_AWS_62), logs-bucket self-logging
        (CKV_AWS_18), SNS encryption (CKV_AWS_26 — AWS-managed key breaks alarm
        delivery; needs CMK)
- [x] Re-scan clean: **78 passed / 0 failed / 17 skipped**
- [ ] (7c) Wire Checkov into the GitHub Actions pipeline (fail the build on a new
      insecure config / unjustified finding)

**7c — GitHub Actions pipeline ✅**
- [x] `.github/workflows/terraform-ci.yml` — 2 jobs: `checkov` (gate, no AWS) +
      `terraform-plan` (needs checkov, push-to-main only, OIDC)
- [x] Role ARN stored as repo **secret** `AWS_ROLE_ARN` (keeps account ID out of
      public workflow code; ARN isn't a credential anyway)
- [x] `permissions: id-token: write` on the plan job (required to mint OIDC token)
- [x] First run: Checkov ✅, plan ❌ — `ReadOnlyAccess` lacks
      `bedrock:ListTagsForResource`. Fixed: scoped inline policy
      `bedrock-tag-read` on the CI role (added to `oidc.tf`); applied locally
      (CI role can't grant its own perms — chicken/egg). Also applied the pending
      7b hardening in the same `apply`.
- [x] Re-run: **both jobs green** — Checkov gate + `terraform plan` via OIDC, no
      stored keys. End-to-end CI working.
- [ ] (optional later) gated apply job via GitHub Environment + approval;
      bump action versions to silence Node 20 deprecation warnings

---

### Phase 7 — COMPLETE ✅
Secure CI/CD: GitHub→AWS auth via **OIDC** (no long-lived keys, repo+branch-scoped,
read-only), **Checkov** scanning (0 failed / 17 justified skips) wired as a build
gate, and a **GitHub Actions** pipeline that runs `terraform plan` on every push to
`main`. Human still runs `apply` manually.

---

### Phase 8 — Cost/usage alerting & model-as-config (professor feedback)

**Context:** two pieces of feedback from the professor, both standard AWS-security
discipline: (1) **alert on model usage**, not just on blocked attacks — usage spikes
are an early-warning signal for a leaked login, a runaway loop, or endpoint abuse, and
a cost circuit-breaker; (2) **change the model through Terraform, not by hand** — the
model ID is currently hardcoded in 5 places, which invites a console edit and causes
**drift** (code stops matching reality). Doing 8a first (quick, low-risk), then 8b.

**8a — Model as a single Terraform variable (no drift, one dial) ✅**
- [x] Create `terraform/variables.tf` with `variable "model_id"`
      (default `us.anthropic.claude-haiku-4-5-20251001-v1:0`)
- [x] `lambda.tf` — replace hardcoded `MODEL_ID` string with `var.model_id`
- [x] `bedrock.tf` — derive all 4 ARNs from the variable
      (`var.model_id` for the inference-profile; `trimprefix(var.model_id, "us.")`
      for the 3 cross-region foundation-model ARNs)
- [x] `terraform fmt` + `validate` + `plan` (clean rebuild after destroy: 33 to add,
      0 to change, 0 to destroy) → `apply` (33 added); `terraform output` for fresh values
- [x] (verify) dial works without code edits via `terraform apply -var="model_id=..."`

**8b — Alert on model token usage (reuse Phase 6 plumbing) ✅**
- [x] `src/handler.py` — capture `result.get("usage", {})` and add `total_tokens`
      to the `ANSWER` log line (metadata only — no prompt/answer text)
- [x] `alerting.tf` — `aws_cloudwatch_log_metric_filter "token_usage"`:
      pattern `{ $.event = "ANSWER" }`, `value = "$.total_tokens"`, `default_value = "0"`
- [x] `alerting.tf` — `aws_cloudwatch_metric_alarm "high_token_usage"`:
      `Sum` over `period = 3600`, threshold above normal, → reuse `alerts` SNS topic
- [x] `apply` (2 added, 1 changed); tested with a low threshold → alert email received,
      then raised threshold to its real value
- [x] (suggestion, done) **AWS Budgets** `budgets.tf` — $-based monthly cost alert
      (ACTUAL > 80% → email), the second/wider cost layer
- [x] **API Gateway throttling** (`apigateway.tf` stage `default_route_settings`:
      rate 5/sec, burst 10) — the *preventive* control vs. the *detective* alarms;
      excess requests get a 429 before reaching Lambda/Bedrock (applied: 1 changed)

**8d — Wrap-up ✅**
- [x] Updated `plan.md` checklist, `learnings.md` (Phase 8: what/why, alternatives,
      memory tricks, Q&A), and README status
- [ ] End-of-phase MCQ quiz (in chat)

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
