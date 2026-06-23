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

### Bootstrapping the backend from scratch (the chicken-and-egg dance)
The state bucket must EXIST before Terraform can store its memory inside it — but
Terraform is the thing that builds the bucket. You can't put the map inside a vault
you haven't built yet. Solved in **two rounds**:
```
ROUND 1 (NO backend block yet):   write bucket  -> init -> plan -> apply
                                  vault built in AWS, map still on the laptop
ROUND 2 (ADD backend "s3" block): write backend -> init (answer "yes")
                                  map copied off the laptop into the S3 vault
```
- Can't be done in one shot: `init` reads the backend FIRST, and on an empty start
  the bucket it names wouldn't exist yet, so Terraform would have nowhere to store
  memory and would fail.
- Big teams sometimes split this into two folders (a tiny "bootstrap" config with
  local state that builds the bucket, then the main config that uses it). For a solo
  project, one folder + two rounds is fine.

### How Terraform decides what to build (state = its ONLY memory)
- Terraform does NOT look at AWS to see what exists. It compares two things:
  `main.tf` (what I WANT) vs the state file (what I REMEMBER building) — and builds
  only the difference.
- So "Terraform won't rebuild things already built" is true ONLY because the state
  file remembers them. Lose the state and Terraform goes blind/amnesiac.
- **Laptop lost, state was local only:** memory gone -> Terraform thinks nothing
  exists -> tries to rebuild everything -> usually ERRORS, because the bucket name
  already exists on AWS (globally unique) and AWS rejects the duplicate "create".
- **Laptop lost, state in S3 (our setup):** new laptop runs `init` + `plan`, reads
  the map from S3, sees everything already built -> "No changes." Nothing rebuilt.
- This is the WHOLE point of remote state: not to protect the rooms (AWS keeps those
  no matter what) but to protect Terraform's MEMORY of them.
- Rescue command if state is ever lost but resources still exist: `terraform import`
  re-tells the notebook "this existing bucket is yours." Fiddly + manual — which is
  exactly why we use remote state, to avoid ever needing it.

### Why the local terraform.tfstate file looks EMPTY in VS Code (this is correct!)
- After Round 2 migration, the real, live map lives in S3. The `terraform.tfstate`
  file still sitting in the folder is just an empty husk — the old address.
- `terraform.tfstate.backup` (~12 KB) is a safety snapshot from just before the move.
- Both are git-ignored leftovers. NEVER hand-edit or hand-delete state files.
- Confirm the real map is alive: `terraform state list` (reads from S3, lists the
  resources) and `aws s3 ls s3://<state-bucket>/global/` (shows the file with a
  real, non-zero size).

### The 3 core commands, refined
- `init`  = get ready: download the provider (tools) AND connect the backend
  (storage). Run once at the start, and again whenever providers or backend change.
- `plan`  = preview only, changes NOTHING. Always read the bottom line
  `X to add, Y to change, Z to destroy` — especially the destroy count.
- `apply` = make it real; shows the plan again and makes you type `yes`.
- Rule of thumb: never `apply` without reading the `plan`.

### Cleaning up a noisy line-ending (CRLF/LF) git diff
- Symptom: `git status` shows a whole file "modified" but the diff is every line
  removed and re-added identically — that's just LF<->CRLF churn, not a real change.
- Fix (Git Bash):
  `git config core.autocrlf input`  (store LF in the repo, don't rewrite on commit)
  `git checkout -- <file>`          (discard the line-ending-only diff)
  `git status`                      (should say "working tree clean")
- Why it matters: a noisy diff hides real changes and makes every future commit look
  scary.

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
- "Build the vault first, THEN move the map in — two rounds, never one." (bootstrap)
- "Terraform can't SEE AWS; it can only REMEMBER. The state file is its memory."
- "Lose the map and Terraform gets amnesia — it rebuilds everything and trips over
  names that already exist."
- "You moved out of the house; the empty rooms stay, but you and your stuff are at
  the new place." (empty local tfstate after migration)
- "init = get ready (tools + storage); plan = preview; apply = make it real."
- "Never apply without reading the plan — the danger hides in the destroy count."
- "A CRLF-only diff is a costume change, not a real one — checkout to undo it."

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
- *How does Terraform build the backend from scratch if the bucket must exist first?*
  Two rounds. Round 1: no backend block — build the bucket with local state. Round 2:
  add the `backend "s3"` block and re-`init` (answer `yes`) to move the map into it.
  Can't be one shot, because `init` reads the backend first and the bucket wouldn't
  exist yet.
- *My terraform.tfstate is EMPTY in VS Code — is that broken?* No, that's proof the
  migration worked. The real map now lives in S3; the local file is an empty leftover.
  `terraform.tfstate.backup` keeps a pre-move snapshot. Confirm with
  `terraform state list` (reads S3) — it should list the buckets.
- *If my laptop is lost, won't Terraform rebuild everything? But it skips what's
  already built, right?* Both, depending on where the state was. Terraform skips
  existing things ONLY because the state file remembers them — it never looks at AWS
  directly. If state was local-only and the laptop dies, the memory is gone, so
  Terraform thinks nothing exists and tries to rebuild all of it (then usually errors
  because the bucket name already exists on AWS). With state in S3 (our setup), a new
  laptop reads the map from S3, sees everything built, and reports "No changes." That
  survival of the MEMORY is the whole reason we moved state to S3.
- *Is `init` just for downloading packages?* Mostly, but it also sets up/connects the
  backend. That's why re-running `init` after adding the S3 backend is what wired
  Terraform to the cloud and offered to migrate state.
- *Why does `git status` show my whole main.tf changed when I didn't touch it?* It's a
  line-ending (CRLF vs LF) costume change, not a real edit. Fix with
  `git config core.autocrlf input` then `git checkout -- <file>`.

---

## Phase 3 — Lambda (Python): the gateway's brain

### What I did
Built and deployed the first working piece of the gateway: an AWS Lambda function
(`secure-genai-gateway-handler`) running a Python skeleton handler, plus its
least-privilege IAM execution role, an explicit CloudWatch log group, and the
Terraform that zips and ships the code. Then test-invoked it (got `200`) and
confirmed the logs landed in CloudWatch.

### Why
Lambda is the "guard at the desk" — the code that reads each request and decides
what to do. We build the guard first as a skeleton (just acknowledges the request)
so the plumbing works before adding the real brains (prompt inspection + Bedrock)
in later phases. Everything is locked down from day one: the guard's badge can do
exactly one thing — write logs — and nothing else.

### How
- **`terraform/lambda.tf`** holds 5 blocks:
  1. `aws_iam_role.lambda_exec` — the role (badge) + trust policy (only the Lambda
     service may assume it).
  2. `aws_cloudwatch_log_group.lambda` — explicit logbook, 14-day retention.
  3. `aws_iam_role_policy.lambda_logging` — permissions policy: only
     `logs:CreateLogStream` + `logs:PutLogEvents`, scoped to our log group's ARN.
  4. `data.archive_file.lambda_zip` — zips `../src` into `lambda.zip`.
  5. `aws_lambda_function.gateway` — the function; `runtime = python3.13`,
     `handler = handler.lambda_handler`, `source_code_hash` so code edits redeploy.
- **`src/handler.py`** — reads `event["prompt"]`, logs its *length* (not content),
  returns `{statusCode: 200, body: ...}`.
- Declared `hashicorp/archive` in `required_providers`; ran `terraform init`.
- Deployed with `terraform apply` (4 added), then:
  `aws lambda invoke --function-name secure-genai-gateway-handler
   --payload '{"prompt":"hello gateway"}' --cli-binary-format raw-in-base64-out
   response.json` → `200`, `prompt_length: 13`.

### The Code, Explained (plain words under each block)

**`main.tf` — added to `required_providers`:**
```hcl
archive = {
  source  = "hashicorp/archive"
  version = "~> 2.0"
}
```
> Adds the "zipping tool" to my project's shopping list, so Terraform can package
> my Python code into a `.zip`. `~> 2.0` = "any 2.x version, not 3.x."

---

**`lambda.tf` — Block A: the role + trust policy**
```hcl
resource "aws_iam_role" "lambda_exec" {
  name = "secure-genai-gateway-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}
```
> Makes an empty "visitor badge" (a role) and writes the rule for **who** may wear
> it: only the Lambda service — nobody and nothing else. `jsonencode` just converts
> my tidy text into the JSON format AWS wants.

---

**`lambda.tf` — Block B: the log group (logbook)**
```hcl
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/secure-genai-gateway-handler"
  retention_in_days = 14
}
```
> Creates the notebook the Lambda will write logs into, and says "auto-delete pages
> older than 14 days" (so logs don't pile up forever). The name must match
> `/aws/lambda/<function-name>` exactly so Lambda writes to *this* notebook.

---

**`lambda.tf` — Block C: the permissions policy**
```hcl
resource "aws_iam_role_policy" "lambda_logging" {
  name   = "lambda-logging"
  role   = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
    }]
  })
}
```
> Writes what the badge is allowed to **do**, and sticks it on the role: only two
> things — open a new log page and write lines on it — and only inside my own log
> group (`:*` = any page of *this* notebook, not all notebooks). Everything else is
> denied by default.

---

**`lambda.tf` — Block D: zip the code**
```hcl
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/lambda.zip"
}
```
> A helper that zips up my `src` folder into `lambda.zip`. `path.module` = "the
> folder this file is in" (`terraform/`); `../src` = "go up one level, then into
> src." `data` = it *prepares* something, it doesn't create cloud stuff.

---

**`lambda.tf` — Block E: the Lambda function**
```hcl
resource "aws_lambda_function" "gateway" {
  function_name    = "secure-genai-gateway-handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  depends_on = [
    aws_iam_role_policy.lambda_logging,
    aws_cloudwatch_log_group.lambda,
  ]
}
```
> Creates the actual guard (Lambda). It wears the badge (`role`), runs `python3.13`,
> and starts at `handler.py`'s `lambda_handler` function. `timeout = 10` = give up
> after 10s. `filename` = the zip to upload. `source_code_hash` = a fingerprint so
> Terraform redeploys whenever my code changes. `depends_on` = build the log group
> and policy *first*.

---

**`src/handler.py` — the brain**
```python
def lambda_handler(event, context):
    logger.info("Gateway invoked.")
    prompt = event.get("prompt", "")
    logger.info("Received a prompt of length %d.", len(prompt))
    body = {"status": "ok", "message": "Gateway received your request.",
            "prompt_length": len(prompt)}
    return {"statusCode": 200, "body": json.dumps(body)}
```
> The code that runs each time the Lambda wakes. It reads the incoming request
> (`event`), safely pulls out the `prompt` (or "" if missing), logs only its
> **length** (never the actual text — that could be sensitive), and sends back a
> "200 OK" reply. `json.dumps` turns the reply dictionary into text.

---

### The permission chain (how the 3 IAM pieces connect)
```
Lambda  --wears-->  Role  --carries-->  Policy  --points at-->  Log group
(guard)            (badge)             (rule)                  (logbook)
```
They're three separate AWS objects on purpose: role & policy live in IAM, the log
group lives in CloudWatch; one role can carry many policies; "who may wear it"
(trust) and "what it unlocks" (permissions) are deliberately kept apart.

### Alternatives considered
- **Managed policy `AWSLambdaBasicExecutionRole`** instead of a custom inline
  policy — easier, but it grants logging on `Resource: "*"` (every log group).
  Rejected: we scope to our own log group's ARN for least privilege.
- **Let Lambda auto-create its log group** — simplest, but the auto-created group
  keeps logs *forever* (cost + privacy risk). Rejected: we create it explicitly
  with 14-day retention.
- **Inline JSON files vs `jsonencode({...})`** for policies — `jsonencode` keeps it
  in one readable Terraform file; chosen for clarity.

### Memory Tricks (Phase 3)
- "Lambda = motion-sensor porch light: off until poked, bills by the millisecond."
- "Role = visitor badge. Trust policy = WHO wears it. Permissions policy = WHAT it
  unlocks." Chain: *Lambda wears role, role carries policy, policy points at logs.*
- "Log the shape, not the secret." (log prompt length, never raw prompt)
- "`init` = go shopping for the tools your code asks for."
- "A leading `/` in Git Bash gets kidnapped into a Windows path —
  `MSYS_NO_PATHCONV=1` calls off the kidnappers."

### Doubts I Asked (Q&A)
- *Why three separate blocks — can't we just interlink them into one?* They're
  three real AWS objects (IAM role, IAM policy, CloudWatch log group), each with its
  own address and lifecycle. One Terraform block = one AWS object; AWS has no
  "combined" object. Keeping them separate lets one role carry several policies and
  keeps trust (who) separate from permissions (what). They *are* linked — via `.id`
  / `.arn` references, which also tell Terraform the build order.
- *Is it "Lambda → log group"?* No — it's the **policy** that links to the log
  group, not the Lambda. Chain: Lambda → role → policy → log group. And the Lambda
  didn't exist yet when we wrote the badge; it shows up last and wears it.
- *Where do I add the `archive` provider?* Inside the **one** existing
  `required_providers { }` block at the top of `main.tf` (not a second block —
  duplicates error out).
- *`aws logs tail` failed with an InvalidParameterException regex error — why?*
  Git Bash auto-converted the `/aws/lambda/...` argument into a Windows path
  (adding a `:`), which broke the log-group name. Fix: prefix the command with
  `MSYS_NO_PATHCONV=1`.
- *What does the `:*` mean in `"${...lambda.arn}:*"`?* It's a **scoped** wildcard:
  "this log group **and any log stream (page) inside it**" — NOT "all log groups."
  Lambda creates a fresh log stream per run, and `PutLogEvents` writes to a stream,
  so the `:*` is needed. Bare `Resource = "*"` (all groups) is the over-broad
  version we avoid. *Any page of THIS notebook, not any notebook.*
- *How are `main.tf` and `lambda.tf` connected?* By **living in the same folder** —
  Terraform reads every `.tf` file in a folder and merges them into one config
  before running. No import/include needed. `main.tf` provides the providers,
  region, and state backend; `lambda.tf`'s resources silently inherit all of that.
- *Can I move blocks between the two files, or put everything in one?* Yes — it's
  all merged anyway, so layout is for humans, not the machine. BUT the one-of-a-kind
  blocks (`terraform`, `required_providers`, `provider "aws"`, and any
  type+nickname pair) must still be **unique** — "split across files" never means
  "have two." Splitting by topic (lambda.tf, s3.tf, ...) is the readable convention.
- *What is the "zipping tool" and how does it relate to Terraform?* Lambda only
  accepts code as a `.zip` (the "envelope"). Terraform's core can't zip, so the
  **archive provider** (a plugin) adds that skill; the `archive_file` block packs
  `src/` into `lambda.zip` automatically on every apply. aws provider = talks to the
  cloud; archive provider = packs the box.
- *Do we always use zipping in Terraform / IaC?* No — only when **deploying our own
  code** (Lambda etc.). Buckets, roles, networks need no zip. And the tool **packs**
  (zips) on my laptop; **AWS unpacks** (unzips) it in the cloud to run it. I pack
  the envelope, AWS opens it.

---

*(Next: Phase 4 — Cognito + API Gateway: the ID check and the only door in.)*
