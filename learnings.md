# Learnings — Secure GenAI Inference Gateway on AWS

A detailed record of each phase: **what** was done, **why**, **how**, what
**alternatives** were considered, and **why they were rejected**. Includes diagrams
where they help. Updated after every completed task.

---

## Phase 1 — Foundations & Setup  *(IN PROGRESS)*

### Goal
Get a safe, working "workbench" before touching cloud infrastructure: the right
tools, a locked-down AWS account, version control, and a guard that stops secrets
from leaking to GitHub.

### Tool decision tree (why each tool)

```
Need to...                        →  Tool            →  Why this one
─────────────────────────────────────────────────────────────────────
edit + save project files         →  VS Code          free, extensible, beginner-friendly
type Linux-style commands on Win  →  Git Bash         Bash shell bundled with Git
track every file change           →  Git              industry standard version control
control AWS by typing             →  AWS CLI          official Amazon command-line tool
build cloud infra as text         →  Terraform        (Phase 2 — install when first used)
```

### Why install via `winget` (and the alternatives rejected)

| Option                         | Verdict   | Reason                                                       |
|--------------------------------|-----------|--------------------------------------------------------------|
| **winget (chosen)**            | ✅ chosen | Built into Win 11, pulls from official publishers, one command |
| Download installers manually   | ❌ no      | Git's wizard has many confusing options a beginner can mis-set |
| Chocolatey (3rd-party manager) | ❌ no      | Extra tool to install/learn; winget already ships with Windows |
| WSL (full Linux subsystem)     | ⏸ later   | Powerful but heavier; Git Bash is enough for this project     |

### The "chicken-and-egg" gotcha (worth remembering)
You want to work in **Git Bash**, but *installing Git is what creates Git Bash*.
So the very first installs run in **PowerShell** (Windows' built-in terminal).
After Git exists, everything moves into Git Bash inside VS Code.

```
PowerShell  ──(install Git)──►  Git Bash now exists  ──►  use Git Bash from here on
```

### Why defer Terraform to Phase 2
Installing a tool right before you first use it makes the *why* click. Terraform
sitting unused for a phase teaches nothing; installing it alongside "Infrastructure
as Code" makes the concept stick.

### Gotcha logged
- **"command not found" right after install** → the terminal only sees tools that
  existed when it opened. Fix: close and reopen the terminal. (Not a real failure.)

### Security mindset this phase
- Install only from **official publishers** (supply-chain safety) — winget handles this.
- The machine is about to hold cloud credentials, so a clean toolchain matters.
- Still to come this phase: **root MFA**, a **least-privilege IAM user**, and a
  **`.gitignore`** created *before* the first commit so secrets can never be pushed.

### Status of Phase 1 tasks
See the checklist in `plan.md`. **Done so far:**
- AWS account confirmed (can log in).
- Tooling installed and verified in Git Bash:
  - Git `2.54.0`
  - AWS CLI `2.34.60` (v2 — the current major version; v1 is legacy)
- VS Code confirmed, terminal already running Git Bash (`MINGW64` prompt).
- **Account secured + CLI connected:**
  - Root has MFA; a separate IAM user (`darsh`) exists with its own MFA.
  - CLI configured (region `us-east-1`, output `json`) and verified with
    `aws sts get-caller-identity` returning an Arn ending in `user/darsh` (not `:root`).

### Identity & credentials — decisions and alternatives

| Decision                              | Chosen | Why / trade-off                                                        |
|---------------------------------------|--------|------------------------------------------------------------------------|
| MFA on root                           | ✅     | A leaked root password alone can't get in; root = total account power  |
| Daily work as IAM user, not root      | ✅     | Limits blast radius if a credential leaks                              |
| IAM user with AdministratorAccess     | ✅*    | *Broad, but pragmatic for a solo learner building many services        |
| Long-lived access keys + `aws configure` | ✅  | Simple for local dev; keys live in `~/.aws`, outside the repo          |
| IAM Identity Center (temp creds)      | ⏸ later | More secure (no long-lived keys) but heavier setup; overkill solo     |
| Passkey / hardware MFA                | ⏸ opt. | Phishing-resistant; authenticator app is fine for learning            |
| OIDC for CI/CD (no keys in pipeline)  | ⏳ P7   | Planned for GitHub Actions in Phase 7 — keyless deploys               |

**Key safety fact learned:** AWS CLI stores credentials in `~/.aws/credentials`
*outside* the project folder by design, so they can't be accidentally committed to
Git. Secrets are never hardcoded in the repo.

**Next:** create the project folder, then a `.gitignore` (BEFORE the first commit).

### Repo creation + `.gitignore` (done)

- Project folder: `~/projects/secure-genai-gateway`, opened in VS Code with `code .`.
- `git init` created the repo (hidden `.git/` folder = the change tracker).
- Branch renamed `master` → `main` with `git branch -m main`.

**Why `master` appeared first:** `git init` uses Git's built-in default branch name,
which is still `master` unless configured. GitHub's default is `main`, so we rename
to match and avoid push-time confusion. (One-time global fix:
`git config --global init.defaultBranch main`.)

**`.gitignore` — purpose and the ordering rule:**
- It's a list of *patterns* (not logic) telling Git what to never track/commit; lines
  starting with `#` are human comments.
- Created **before** the first commit on purpose: `.gitignore` only affects files that
  aren't *already* tracked. Ignore-after-commit is too late.
- The non-obvious danger it guards: `*.tfstate` (Terraform state) can hold secrets in
  plain text — treat it like a password and never commit it.

```
git init  ─►  branch = master (Git default)
   │
   └─►  git branch -m main  ─►  branch = main (matches GitHub)

.gitignore written FIRST  ─►  secrets/state never enter Git history
```

**Next:** add the three docs to the repo and make the first commit.

---

## Phase 2 — Terraform basics  *(not started)*
_To be documented once we begin._

## Phase 3 — Cognito  *(not started)*
## Phase 4 — API Gateway + Lambda  *(not started)*
## Phase 5 — Bedrock + Guardrails  *(not started)*
## Phase 6 — CloudWatch + SNS  *(not started)*
## Phase 7 — GitHub Actions + Checkov  *(not started)*
## Phase 8 — Hardening, testing, teardown  *(not started)*
