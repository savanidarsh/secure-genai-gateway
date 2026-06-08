# Project Plan — Secure GenAI Inference Gateway on AWS

This is the master map for the whole project: the concept, the architecture, the
phases, and the **checklist** to track progress. Updated after every completed task.

---

## 1. Concept (plain English)

We're building a **security checkpoint** between users and an AI model. Think of a
nightclub with one AI genius inside. People line up to ask the genius questions, but
some are sneaky — they try to trick it, sneak out secrets, or shout abuse. So we put
staff at the door:

- **Cognito** = the bouncer checking IDs (authentication = proving who you are).
- **API Gateway** = the front door / reception desk.
- **Lambda** = the guard doing the actual inspecting.
- **Bedrock** = the AI genius in the back.
- **Guardrails** = the metal detector + censor (blocks/redacts bad content).
- **CloudWatch** = the cameras + logbook.
- **SNS** = the alarm/pager.
- **S3** = the storage room.
- **Terraform** = the building blueprint (Infrastructure as Code).
- **GitHub Actions** = the construction crew (CI/CD).
- **Checkov** = the building inspector for the blueprint.

**Memory trick:** *Bouncer → Door → Guard → Genius → Detector → Cameras → Alarm.*

---

## 2. Architecture (request flow)

```
 USER ─prompt─► [Cognito: logged in?] ─► [API Gateway: front door]
                                              │
                                              ▼
                                    [Lambda guard]
                                     │        │
                          scan prompt│        │ if clean, ask model
                                     ▼        ▼
                            [Guardrails]   [Bedrock AI]
                                     │        │
                                     └──►[Lambda guard]: scan the ANSWER
                                              │
                                              ▼
                                          USER (clean reply)

 Always-on: CloudWatch (logs/metrics) · SNS (alerts) · S3 (storage)
```

Two scans, not one — **the prompt going in AND the answer coming out** both get
inspected. That's the core security idea.

---

## 3. Phases (goal of each)

| # | Phase                          | Goal                                                        |
|---|--------------------------------|-------------------------------------------------------------|
| 1 | Foundations & Setup            | Tools, secure AWS account, Git/GitHub, the secret-leak guard |
| 2 | Terraform basics               | Write infra as code; connect safely to AWS; remote state    |
| 3 | Cognito                        | Add the login/bouncer                                       |
| 4 | API Gateway + Lambda           | Build the front door + guard skeleton                       |
| 5 | Bedrock + Guardrails           | Connect the AI brain + injection/PII/toxicity filtering     |
| 6 | CloudWatch + SNS               | Logging, metrics, attack alerts                             |
| 7 | GitHub Actions + Checkov       | Auto-build/deploy + security scan the blueprint             |
| 8 | Hardening, testing, teardown   | Tighten, test end-to-end, delete resources to stop costs    |

---

## 4. Master checklist

### Phase 1 — Foundations & Setup
- [x] AWS account exists and can log in
- [x] Install VS Code, Git (Git Bash), AWS CLI
- [x] Verify installs (`git --version` → 2.54.0, `aws --version` → aws-cli v2.34.60)
- [x] Set Git Bash as the default VS Code terminal (confirmed: MINGW64 prompt)
- [x] Secure AWS account: root MFA on; IAM user has MFA; now working as IAM user
- [x] Create a least-privilege IAM user/identity for daily work (user `darsh`, AdministratorAccess — broad, OK for learning)
- [x] Configure the AWS CLI with that identity (region us-east-1; verified via `aws sts get-caller-identity` → `user/darsh`)
- [x] Create the project folder in VS Code (`~/projects/secure-genai-gateway`)
- [x] Create `.gitignore` (BEFORE first commit) — blocks secrets, tfstate, junk
- [x] `git init` + rename branch to `main`
- [ ] First commit (after the three docs are in the repo)
- [ ] Create GitHub repo and push
- [ ] Create README.md, plan.md, learnings.md
- [ ] Phase 1 quiz + summary

### Phase 2 — Terraform basics
- [ ] Install Terraform
- [ ] Provider block + version pinning
- [ ] Remote state backend (S3) — and why local state is risky
- [ ] First safe resource + `plan`/`apply` workflow

### Phase 3 — Cognito
- [ ] User pool + app client
- [ ] Token-based auth flow understood

### Phase 4 — API Gateway + Lambda
- [ ] Lambda (Python) skeleton
- [ ] API Gateway wired to Lambda
- [ ] Cognito authorizer on the endpoint

### Phase 5 — Bedrock + Guardrails
- [ ] Enable Bedrock model access
- [ ] Create a Guardrail (injection / PII / toxicity)
- [ ] Scan prompt in, scan answer out

### Phase 6 — CloudWatch + SNS
- [ ] Structured logging of every interaction
- [ ] Metrics + alarm on attacks
- [ ] SNS topic + subscription for alerts

### Phase 7 — GitHub Actions + Checkov
- [ ] CI pipeline (plan on PR)
- [ ] Checkov scan gate
- [ ] Secure deploy (OIDC, no long-lived keys)

### Phase 8 — Hardening, testing, teardown
- [ ] End-to-end attack tests
- [ ] Least-privilege review
- [ ] `terraform destroy` to stop costs

---

## 5. Security principles (non-negotiable)

1. **Never use the AWS root account for daily work.** Lock it with MFA, then leave it alone.
2. **Least privilege.** Every identity gets only the permissions it truly needs.
3. **No secrets in Git, ever.** `.gitignore` is created *before* the first commit.
4. **Inspect both directions.** Prompt in AND answer out are scanned.
5. **Log everything, alert on attacks.** You can't defend what you can't see.
6. **Scan infra before deploy.** Checkov checks the blueprint, not just the running system.

---

## 6. Cost & teardown notes

- Most services are cheap/free-tier during learning; Bedrock model calls cost per use.
- Avoid leaving anything running idle.
- Final phase runs `terraform destroy` to remove everything and stop charges.

---

## 7. Key design decisions (summary)

| Decision                         | Why                                                          |
|----------------------------------|--------------------------------------------------------------|
| Terraform for infra              | Repeatable, reviewable, version-controlled cloud setup       |
| Two-direction scanning           | Attacks/leaks can appear in the model's output too           |
| Cognito over rolling our own auth| Auth is hard to get right; use a battle-tested service       |
| Remote state (S3) over local     | Local state can be lost or accidentally committed            |
| Checkov in CI                    | Catch misconfigurations before they ever deploy              |

*(Full reasoning + rejected alternatives live in `learnings.md`.)*
