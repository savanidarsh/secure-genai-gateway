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
- VS Code as editor; **Git Bash** set as the default VS Code terminal.
- AWS CLI v2 installed; `aws configure` set region `us-east-1`, output JSON.
- Verified identity with `aws sts get-caller-identity` (returns the IAM user ARN).
- Git: `git init` -> `.gitignore` -> `git add` -> `git commit` -> `git push`.

### Alternatives considered
- **IAM Identity Center** instead of `aws configure` long-lived keys — more secure
  (short-lived logins); deferred as a future upgrade for simplicity now.

### Memory Tricks (Phase 1)
- "Root is the king's crown — lock it in a vault and never wear it."
- "Add = pack the box. Commit = seal the box. Push = mail the box. Status = peek."
- "Sweep the floor before the camera starts recording." (.gitignore before first commit)

### Doubts I Asked (Q&A)
- *Why not just use root?* Root is the master key to everything; if it leaks, the
  whole account is gone. Use a named IAM user day-to-day.

---

## Phase 2 — Terraform / Infrastructure as Code

### What I did
Installed Terraform, wrote my first config (provider, version-pinned), ran
`init` and `plan`, provisioned a hardened S3 logs bucket, then a hardened S3 state
bucket, and finally migrated Terraform's state to a remote S3 backend.

### Why
Infrastructure as Code = the cloud setup lives as reviewable text in Git, instead
of un-trackable clicks. Every change becomes auditable **before** it's built.

### How — the Terraform lifecycle
```
write .tf  ->  init  ->  plan  ->  apply
describe       unpack    dry-run   build
the goal       tools     no change  for real
```

### How — the resource + reference pattern
```
resource "TYPE" "NICKNAME" {           # "I want a [type] I'll call [nickname]"
  setting = value
}

bucket = aws_s3_bucket.logs.id         # the WIRE: points at another resource
         |TYPE          |NICK |ATTR
```
The nickname is a Terraform-only label (AWS never sees it). The reference expands
into the real value (the bucket name) before Terraform talks to AWS, and it also
sets build ORDER (bucket first, then the things that point at it).

### What I built (two hardened buckets)
```
secure-genai-gateway-logs-darsh-1522       (for future logs)
secure-genai-gateway-tfstate-darsh-1522    (for Terraform state)
  each one:
    [lock]    Block Public Access  (aws_s3_bucket_public_access_block, 4 x true)
    [crypto]  Encryption at rest   (aws_s3_bucket_server_side_encryption_configuration, AES256)
    [history] Versioning           (aws_s3_bucket_versioning, Enabled)
```

### New syntax learned — nested blocks
A setting that's a *group* of fields gets its own { } box with **no = sign**
(e.g. `rule { ... }`, `versioning_configuration { ... }`).

### Remote state backend (the final piece)
- State (Terraform's memory) used to live only on the laptop (local backend).
- Added a `backend "s3"` block inside the `terraform { }` block:
  `bucket`, `key`, `region`, `encrypt = true`, `use_lockfile = true`.
- Ran `terraform init` and answered `yes` to migrate the local state into S3.
- Now the laptop reads/writes state in S3; the local file is just a leftover.
- **Gotcha:** the backend block CANNOT use references/variables — it's read first,
  before the dependency map exists, so the bucket name must be plain text.

### Alternatives considered
- **OpenTofu** vs Terraform — open-source twin; stayed on Terraform (locked stack).
- **Local state** vs **remote backend** — moved to remote: survives the laptop,
  shareable, lockable, and required for Phase 7 CI/CD.
- **AES256 (SSE-S3, free)** vs **aws:kms (customer keys, more control + cost)** —
  chose AES256 for learning; flagged KMS as an upgrade.
- **One bucket for everything** vs **separate logs + state buckets** — kept them
  separate (different jobs, different sensitivity).
- **DynamoDB lock table** vs **native S3 locking (`use_lockfile`)** — used native
  S3 locking (simpler, no extra service; available in Terraform 1.10+).
- **Long-lived IAM keys** vs **OIDC** — keys for now; OIDC planned for Phase 7.

### Folder structure
```
secure-genai-gateway/
├── .gitignore               # commit it — just the ignore list
├── README.md / plan.md / learnings.md
└── terraform/
    ├── main.tf              # terraform{} + backend + provider + resources
    ├── .terraform.lock.hcl  # COMMIT: exact provider + checksum
    ├── .terraform/          # IGNORED: downloaded plugins
    └── terraform.tfstate    # IGNORED leftover (real state now in S3)
```

### Memory Tricks (Phase 2)
- "Clicking is cooking from memory; Terraform is cooking from a written recipe."
- "terraform{} = oven settings; provider aws{} = kitchen address; `~>` = newer's
  fine, don't move house." (version pinning)
- "init = unpack your toolbox before the job."
- "plan = read the blueprint; apply = pick up the hammer." (apply makes you type `yes`)
- "A recipe tells the cook the STEPS; main.tf tells Terraform the GOAL." (declarative)
- "Ignore the treasure map (tfstate); commit the receipt (lock.hcl)."
- "`.gitignore` is the do-not-pack list — never packed, sealed, or mailed; it stays
  on your desk at home."
- "Bouncer checks your ID != you're on the VIP list." (authentication vs authorization)
- "Rotate keys = change the locks." (temp creds = "a key that melts after an hour")
- "LF = Linux's single tap; CRLF = Windows' double tap; Git just translates."
- "Nickname is for your eyes; the `bucket =` line is the actual wire."
- "TYPE.NICKNAME.ATTRIBUTE = reach into the named thing, grab one piece."
- "The reference is the question; the value it becomes is the answer."
- ".id hands over the bucket's one-of-a-kind name."
- "An S3 bucket name is like a website domain — one on the whole planet."
- "Four locks on one door — all true, nobody gets in." (Block Public Access)
- "Scramble it while it sleeps." (encryption at rest)
- "Keep every old copy, so nothing's quietly erased." (versioning)
- "A nested block is a setting that's a box with its own fields (no =)."
- "Terraform reads the saved file, not your screen." (save before plan!)
- "Terraform only cooks with the ingredients in the room it's standing in." (current folder)
- "Code lives in GitHub; the map lives in the S3 vault. Lose your laptop, only the
  vault saves you." (remote state)
- "Build the vault, then hand Terraform the key." (apply the state bucket before
  pointing the backend at it)
- "The backend is read first, so it only understands plain text — no nicknames."
- "One shared whiteboard, many writers, one lock so they take turns." (state locking)

### Doubts I Asked (Q&A)
- *Could the AWS connection not be live?* It's confirmed live whenever
  `get-caller-identity` returns an ARN instead of an error. It proves *who I am*
  (authentication), not *what I can do* (authorization).
- *What does "rotate" keys mean?* Swap old access keys for new ones, then delete
  the old — limits the damage if a key leaks.
- *Why commit the lock file but ignore tfstate?* lock.hcl = receipt (genuine tools
  + checksum, no secrets); tfstate = treasure map (can hold secrets in plaintext).
- *Is main.tf a recipe with steps?* No — it's declarative. It describes the end
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
- *Does `.gitignore` mean those files only stay on my computer?* Yes — listed files
  aren't tracked/staged/committed/pushed, so they stay local and never reach GitHub.
  Catch: it only works on files Git isn't already tracking.
- *Why move state from the laptop to S3?* Survival (it doesn't die with the laptop),
  shareable (a new laptop or the CI/CD pipeline can read it), and safety (encrypted,
  versioned, locked). If the laptop died, local-only state would be lost and
  Terraform would get amnesia and try to recreate existing resources.
- *Are we removing `.tfstate` from `.gitignore` and putting it in S3?* No — the
  ignore rule stays. The file simply moves from one non-Git place (laptop) to
  another non-Git place (S3). Git is never involved either way.
- *Will Part 2 connect the laptop to S3?* Yes — the `backend "s3"` block + a
  re-`init` (with `yes`) point the laptop at the S3 vault and move the map there.
- *Will GitHub Actions and the state be wired together?* Yes, in Phase 7 — both the
  laptop and the pipeline use the same `backend "s3"` config, so they read/write the
  same map. Locking lets multiple writers take turns.
- *git add vs status vs commit vs push?* add = pack (stage), commit = seal+save
  locally, push = mail to GitHub, status = peek (read-only, changes nothing).

---

*(Next: Phase 3 — AWS Lambda, the gateway's brain.)*
