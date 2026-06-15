# Learnings

Detailed, per-phase notes: **what** was done, **why**, **how**, and the
**alternatives** considered. Each phase ends with a **Memory Tricks** list and a
**Doubts I Asked (Q&A)** section so this file works as a revision sheet.

---

## Phase 1 — Foundations & Setup

### What I did
Set up the whole workshop before building anything: editor + terminal + AWS CLI,
locked down the AWS account with MFA, created a non-root IAM user, set up Git, and
pushed a first commit to a private GitHub repo.

### Why
You don't build in an unsafe room. Locking the account (MFA, no root use) and
guarding Git (`.gitignore` before the first commit) means secrets can never sneak
into history, and a stolen password alone can't get in.

### How
- VS Code as editor; **Git Bash** set as the default VS Code terminal (Linux-style
  shell on Windows).
- AWS CLI v2 installed; `aws configure` set region `us-east-1`, output JSON.
- Verified identity with `aws sts get-caller-identity` (returns the IAM user ARN).
- Git: `git init` → `.gitignore` → `git add` → `git commit` → `git push`.

### Alternatives considered
- **IAM Identity Center** instead of `aws configure` long-lived keys — more secure
  (short-lived logins); deferred as a future upgrade for simplicity now.

### Memory Tricks (Phase 1)
- "Root is the king's crown — lock it in a vault and never wear it."
- "Add = pack the box. Commit = seal the box. Push = mail the box."
- "Sweep the floor before the camera starts recording." (`.gitignore` before first commit)

### Doubts I Asked (Q&A)
- *Why not just use root?* Root is the master key to everything; if it leaks, the
  whole account is gone. Use a named IAM user day-to-day.

---

## Phase 2 — Terraform / Infrastructure as Code

### What I did
Installed Terraform, wrote my first config (provider, version-pinned), ran
`init` and `plan`, then provisioned my first real resource — an S3 bucket — and
hardened it with three security resources. Committed and pushed.

### Why
Infrastructure as Code = the cloud setup lives as reviewable text in Git, instead
of un-trackable clicks. Every change becomes auditable **before** it's built.

### How — the Terraform lifecycle
```
write .tf  →  init  →  plan  →  apply
describe      unpack   dry-run   build
the goal      tools    no change  for real
```

### How — the resource + reference pattern
```
resource "TYPE" "NICKNAME" {           # "I want a [type] I'll call [nickname]"
  setting = value
}

bucket = aws_s3_bucket.logs.id         # the WIRE: points at another resource
         └ TYPE        └ NICK └ ATTR
```
The nickname is a Terraform-only label (AWS never sees it). The reference expands
into the real value (the bucket name) before Terraform talks to AWS, and it also
sets build ORDER (bucket first, then the things that point at it).

### What I built (the hardened bucket)
```
secure-genai-gateway-logs-darsh-1522
  🔒 Block Public Access  (aws_s3_bucket_public_access_block — 4 × true)
  🔐 Encryption at rest   (aws_s3_bucket_server_side_encryption_configuration, AES256)
  🕰️ Versioning           (aws_s3_bucket_versioning, Enabled)
```

### New syntax learned — nested blocks
A setting that's a *group* of fields gets its own `{ }` box with **no `=` sign**
(e.g. `rule { ... }`, `versioning_configuration { ... }`).

### Alternatives considered
- **OpenTofu** vs Terraform — open-source twin; stayed on Terraform (locked stack,
  bigger guide ecosystem now).
- **Local state** vs **remote backend** — local is fine for solo learning; remote
  matters with teammates/secrets. Deferred to end of Phase 2.
- **AES256 (SSE-S3, free)** vs **aws:kms (customer keys, more control + cost)** —
  chose AES256 for learning; flagged KMS as an upgrade.
- **One big bucket block** vs **separate resources** — modern AWS provider uses
  separate resources, so we did too.
- **Long-lived IAM keys** vs **OIDC** — keys for now; OIDC planned for Phase 7.

### Folder structure
```
secure-genai-gateway/
├── .gitignore               # commit it — just the ignore list
├── README.md / plan.md / learnings.md
└── terraform/
    ├── main.tf
    ├── .terraform.lock.hcl   # COMMIT: exact provider + checksum
    ├── .terraform/           # IGNORED: downloaded plugins
    └── terraform.tfstate     # IGNORED: can hold secrets in plaintext
```

### Memory Tricks (Phase 2)
- "Clicking is cooking from memory; Terraform is cooking from a written recipe."
- "terraform{} = oven settings; provider aws{} = kitchen address; `~>` = newer's
  fine, don't move house." (version pinning)
- "init = unpack your toolbox before the job."
- "plan = read the blueprint; apply = pick up the hammer." (and apply makes you
  type `yes`)
- "A recipe tells the cook the STEPS; main.tf tells Terraform the GOAL."
  (declarative — you describe the house, Terraform is the builder)
- "Ignore the treasure map (tfstate); commit the receipt (lock.hcl)."
- "Commit the bouncer's list (.gitignore); never post the treasure map."
- "Bouncer checks your ID ≠ you're on the VIP list." (authentication vs authorization)
- "Rotate keys = change the locks." (temp creds = "a key that melts after an hour")
- "LF = Linux's single tap; CRLF = Windows' double tap; Git just translates."
- "Nickname is for your eyes; the `bucket =` line is the actual wire."
- "TYPE.NICKNAME.ATTRIBUTE = reach into the named thing, grab one piece."
- "The reference is the question; the value it becomes is the answer."
- ".id hands over the bucket's one-of-a-kind name."
- "An S3 bucket name is like a website domain — one on the whole planet."
- "Four locks on one door — all `true`, nobody gets in." (Block Public Access)
- "Scramble it while it sleeps." (encryption at rest)
- "Keep every old copy, so nothing's quietly erased." (versioning)
- "A nested block is a setting that's a box with its own fields (no `=`)."
- "Terraform reads the saved file, not your screen." (save before plan!)
- "Terraform only cooks with the ingredients in the room it's standing in." (runs
  on .tf files in the current folder only)

### Doubts I Asked (Q&A)
- *Could the AWS connection not be live?* It's confirmed live whenever
  `get-caller-identity` returns an ARN instead of an error. It proves *who I am*
  (authentication), not *what I can do* (authorization).
- *What does "rotate" keys mean?* Swap old access keys for new ones, then delete
  the old — limits the damage if a key leaks.
- *Why commit the lock file but ignore tfstate?* lock.hcl = receipt (genuine tools
  + checksum, no secrets); tfstate = treasure map (can hold secrets in plaintext).
- *Is main.tf a recipe with steps?* No — it's *declarative*. It describes the end
  goal, not ordered steps; Terraform works out the order and only fixes differences.
- *Why doesn't AWS see the nickname if it's the bucket's name?* Two different
  names: the nickname ("logs") is a Terraform-only label; the real name is in the
  `bucket = "..."` line.
- *Does the lock apply to anything nicknamed "logs"?* No — the `bucket =` line is
  what connects them, not the matching nickname.
- *How is it wired with only `.id`?* `.id` = the bucket's globally-unique name, and
  a unique name points to exactly one bucket.
- *Is the `bucket =` line only a Terraform reference?* The right half is Terraform
  shorthand; the left half (`bucket`) is a real AWS setting, and the value the
  shorthand becomes IS sent to AWS.
- *What if I have 2 buckets?* Give each a different nickname; each lock points to
  its own bucket via its own `bucket =` reference.

---

*(Next: remote state backend to close Phase 2, then Phase 3 — Lambda.)*
