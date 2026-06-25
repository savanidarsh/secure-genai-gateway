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

---

## Phase 4 — Cognito + API Gateway (the ID check and the only door in)

### What we built (and why)
A user can no longer talk to the Lambda directly. Now they must (1) prove who they
are at **Cognito** and get a token, then (2) knock on the **API Gateway** front door
and show that token, where a **JWT authorizer** checks it before anything reaches the
Lambda. No token = bounced at the door (`401`), Lambda never runs.

### The nightclub model
```
 User's app (curl/browser)          = a visitor
   |  logs in (quotes app client ID)
   v
 Cognito user pool                   = ID desk + guest list + wristband printer
   |  returns ID / access / refresh tokens
   v
 API Gateway (HTTP API)              = the only front door
   |  JWT authorizer = the bouncer (checks issuer + audience + expiry)
   v
 Lambda integration (AWS_PROXY)      = hallway to the guard
   v
 Lambda (Phase 3)                    = the guard who handles the request
```

### Request flow (the flowchart — 401 vs 200)
```
                Your app (curl / browser)  — the visitor
                         |
                         | 1. log in (email + password)
                         v
                 Cognito user pool  — checks id, prints the JWT
                         |
                         | 2. returns tokens — keep the ID token
                         v
                 App holds the ID token  — the wristband
                         |
                         | 3. POST /chat  +  token in Authorization header
                         v
            API Gateway — JWT authorizer  (the bouncer)
            checks: issuer · audience · expiry
                   /                            \
           valid token                          no / bad token
                |                                     |
                v                                     v
        Lambda (the guard runs)              401 Unauthorized
                |                            (bounced — Lambda never runs)
                | reply
                v
        200 OK — reply returned to the app
```
> One sentence to remember it all: **"Wristband from the booth, checked by the
> bouncer, before the guard ever sees you."** Colours in the live diagram: blue =
> Cognito (issues), teal = authorizer (decides), green vs red = the two outcomes.

### The pieces (Terraform -> AWS)
- `aws_cognito_user_pool` — the guest directory (email login, strong password policy).
- `aws_cognito_user_pool_client` — the **registered lane** an app uses to log in.
  `generate_secret = false` because a CLI/browser app can't hide a secret.
- `aws_apigatewayv2_api` (`protocol_type = "HTTP"`) — the door.
- `aws_apigatewayv2_integration` (`AWS_PROXY`, payload `2.0`) — the hallway to Lambda.
- `aws_lambda_permission` — lets the API Gateway *service* invoke the Lambda
  (resource-based permission — the OTHER direction from the execution role).
- `aws_apigatewayv2_authorizer` (`JWT`) — the bouncer. `jwt_configuration` pins
  `audience` (our app client ID) and `issuer` (our pool's URL).
- `aws_apigatewayv2_route` (`POST /chat`, `authorization_type = "JWT"`) — the rule
  that actually *stations* the bouncer on this route.
- `aws_apigatewayv2_stage` (`$default`, `auto_deploy = true`) — publishes the URL.

### The two-direction permission idea (important)
```
Execution role (Phase 3)    = the guard's OWN keyring   -> what the Lambda CAN DO
Lambda permission (Phase 4) = a note at the guard's desk -> WHO may invoke the Lambda
```
People forget the second one and then get `500`s / `AccessDenied` from API Gateway.

### Why the ID token, not the access token
The authorizer is configured with `audience = app client ID`. Cognito's **ID token**
carries that value in its `aud` claim; the **access token** does not. So only the ID
token passes audience validation. (Classic gotcha.)

### The test that proves it
```
no Authorization header  -> HTTP 401 Unauthorized   (lock works)
valid ID token in header -> HTTP 200 OK             (reaches Lambda)
```
`prompt_length: 0` on the 200 is expected: with proxy + payload 2.0 the prompt now
arrives in `event["body"]` (a JSON string), not `event["prompt"]`. Parsing is a
Phase 5 job.

### Alternatives considered
- **REST API (API Gateway v1)** instead of HTTP API — more security knobs (WAF,
  request validation, resource policies) but more boilerplate and slightly pricier.
  Rejected for now: HTTP API has a native JWT authorizer and is the simplest correct
  fit. (Revisit if we need WAF in front.)
- **Client secret on the app client** — adds an app-level password, but a CLI/browser
  can't keep it hidden, so it's false security. Rejected -> `generate_secret = false`.
- **`USER_SRP_AUTH`** (password never leaves the device) — more secure than
  `USER_PASSWORD_AUTH`, but needs a real client SDK to do the math, so it's awkward to
  test from raw CLI. Used `USER_PASSWORD_AUTH` for learning; flagged for production.
- **Custom Lambda authorizer** instead of the built-in JWT authorizer — more flexible
  but is code we'd have to write, secure, and maintain. Rejected: the managed JWT
  authorizer validates Cognito tokens for free.

### Memory Tricks (Phase 4)
- "The **app client is the lane**; **Cognito is the booth** that prints the wristband."
- "**A secret you have to hand to the customer isn't a secret.**" (`generate_secret = false`)
- **Two passwords:** the *user's* password vs the *app's* client secret — different things.
- "Execution role = the guard's keyring (what he opens). Lambda permission = the note
  at his desk (who may ring his bell)." Two directions.
- Bouncer checks **issuer** (which booth) + **audience** (which lane) + **expiry**.
- "**Use the ID token, not the access token** — only the ID token carries `aud`."
- "**401 without a wristband = success.** The lock works."
- "`POST /chat` = drop a message at the **/chat window** using the **POST** action."
- "Resources are **siblings, never nested** — two appliances side by side, not a
  microwave inside a fridge."
- "**Concept in your head, exact name from the docs, `validate` to confirm.**"

### Doubts I Asked (Q&A)
- *`generate_secret = false` — what's the secret?* There are **two** passwords: the
  *user's* password (proves the human) and the *client secret* (an app-level password
  that proves the app). A secret only helps if it can be hidden — fine on a backend
  server, useless in a CLI/browser where anyone can read the code. So we skip it.
- *Does the app client hand the JWT to the user?* No. **Cognito** issues the tokens;
  the app client is just the registered lane the login goes through. You get three
  tokens: **ID** (who you are — the wristband we check), **access** (what you may
  access), **refresh** (to get fresh ones when they expire ~1 hr).
- *Is the app client like an HTTP client / is it the browser or CLI?* No. The
  browser/CLI is the running **HTTP client** (the visitor). The **app client** is a
  *config record in Cognito* — the approved doorway the visitor must use. (And both
  are different from the **HTTP API**, which is API Gateway, the front door.)
- *Is `aws_apigatewayv2_api` a name found in AWS?* It's a **Terraform** name
  (`provider_service_thing`). `apigatewayv2` = AWS's name for API Gateway **v2** (HTTP
  + WebSocket). In the Console it shows as an **HTTP API**. Confirm any name on the
  Terraform Registry docs.
- *Do I need to memorize AWS service names to write Terraform?* No — you bring the
  *concept*, the **docs** give the exact name + arguments, and `terraform validate`
  catches a wrong name instantly. Keep the docs tab open; everyone looks them up.
- *What does `route_key = "POST /chat"` mean?* `/chat` is the **address** (a window);
  `POST` is the **action** (sending data in, vs `GET` = reading). Only that exact
  combination is handled; anything else is a 404.
- *Are the outputs just for the test?* No — they don't create anything (just print
  values), they cost nothing, and the Phase 7 CI/CD pipeline reads them too. Never put
  secrets in outputs (mark `sensitive = true` if you must).
- *Why was my edit not showing up?* The file genuinely wasn't saved (same timestamp /
  byte count on disk). Fix: **Ctrl+S** (an unsaved tab shows a white dot), and confirm
  you're editing the file at the real project path. Lesson: the saved file on disk is
  the source of truth — `terraform validate` reads *that*, not the editor buffer.
- *Why did Terraform complain about my resource block?* A `resource` was typed
  **inside** another `resource`. Blocks can't nest — each must start at column 1 after
  the previous block's closing `}`. Two siblings, not one-inside-the-other.
- *What is `/chat`?* It's a **path** (a.k.a. route) — a labelled doorway on the API,
  like a sign over a service window. Not special to AWS; I named it myself (could've
  been `/ask`). The full address is base URL + path:
  `https://...amazonaws.com/chat`. Right now it's the only door open — knocking
  anywhere else returns `404 Not Found`.
- *Who uses/references `/chat`?* The **caller** (the client side). `curl`, or a future
  web/mobile app, writes `/chat` into the request URL to pick the right doorway. It's a
  shared label: the **caller writes** it, and **API Gateway listens for** it (our
  `route "POST /chat"`). Both sides must agree on the exact spelling or it's a 404. The
  human end-user never sees it — it lives in the app's code.
- *Is the doorway name how you call the appropriate API?* Almost — it picks the right
  **route inside the same API**, not a different API. One building (one API), several
  labelled windows (`/chat`, `/login`, `/history`), each steering to its own handler.
  We've built exactly one window so far: `/chat` -> Lambda.

---

---

## Phase 5 — Bedrock + Guardrails (the model, behind a safety filter)

### What we built (and why)
The guard can finally *answer* — but only through a bouncer. The Lambda now calls
**Claude Haiku 4.5** on **Amazon Bedrock**, and every call is wrapped in a **Bedrock
Guardrail** that inspects the prompt going in and the answer coming out. Dirty input
or output is blocked or redacted before anyone sees it. This is the literal heart of
the whole project: *inspect, then decide.*

### The flow we added
```
prompt --> [Guardrail checks INPUT] --> Claude Haiku --> [Guardrail checks OUTPUT] --> answer
                  |                                              |
              block / redact                               block / redact
```

### The pieces (Terraform -> AWS)
- `aws_bedrock_guardrail` — the safety filter. Two policy blocks:
  - `content_policy_config` — 6 ML classifiers: HATE/INSULTS/SEXUAL/VIOLENCE/
    MISCONDUCT (input+output `HIGH`) and **PROMPT_ATTACK** (input `HIGH`, output
    `NONE` — injection only exists on the way *in*).
  - `sensitive_information_policy_config` — PII: EMAIL/PHONE → `ANONYMIZE` (redact,
    request continues), SSN/CREDIT_CARD → `BLOCK` (too dangerous, stop the request).
- `aws_bedrock_guardrail_version` — a frozen, numbered snapshot. Production pins a
  *version*, not the live `DRAFT`, so a half-finished edit can't change enforcement.
- `data "aws_caller_identity"` — a **lookup** (not a build) to get our account number
  for the profile ARN.
- `aws_iam_role_policy.lambda_bedrock` — least-privilege: InvokeModel/Converse/
  GetInferenceProfile on the profile ARN **+ the foundation-model ARN in each
  cross-region destination**, and ApplyGuardrail on our guardrail. No `Resource = "*"`.
- `src/handler.py` — parses `event["body"]`, calls `bedrock.converse(...)` with
  `guardrailConfig`, returns the answer, and flags `stopReason == "guardrail_intervened"`
  as `blocked`.
- Lambda `environment` vars: `MODEL_ID` (the `us.` profile), `GUARDRAIL_ID`,
  `GUARDRAIL_VERSION`. Timeout bumped 10 → 30.

### The cross-region inference gotcha (the big one)
Claude Haiku on Bedrock is **cross-region inference**: when you call the `us.` profile,
AWS may actually run the request in any of several US regions to balance load. Because
AWS grants model permission **per region**, a least-privilege policy must allow the
model in **every** destination region (us-east-1, us-east-2, us-west-2) — or you get a
*confusing, intermittent* `AccessDeniedException` only when AWS happens to route
elsewhere. ARN shapes also differ: the **profile** ARN has your account number (it's
yours); the **foundation-model** ARNs use `::` with no account number (they're AWS's).

**The vending-machine analogy (explain-like-I'm-14):**
The Lambda is a kid buying one specific snack (the model). The snack is sold from a
chain of vending machines in 3 cities. An app (the **inference profile**) randomly
picks *which* city's machine serves you, based on which is least busy — you don't
choose. Catch: **each city's machine needs its own key card** (per-region permission).
Give the kid only a City-1 card and it works when the app picks City 1, but throws
`AccessDenied` when it picks City 2 or 3 — random, maddening, even though the code is
perfect. Fix: hand over a key card for **all three cities** up front. That's exactly
what the `Resource` list does. *"The profile picks the city at random, so hand a key to
every city it might pick."*

**Where + what we changed:** all in `terraform/bedrock.tf`, block
`aws_iam_role_policy "lambda_bedrock"`. The `Resource` list = the key cards:
```hcl
Resource = [
  # The app that picks the city (the inference profile) — YOURS (has account #)
  "arn:aws:bedrock:us-east-1:<ACCOUNT_ID>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
  # The snack machine, one card per city — AWS's (empty :: , no account #)
  "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",  # City 1
  "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",  # City 2
  "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"   # City 3
]
```
The line everyone forgets is the **per-city model cards** (the last three) — people
write only the profile + one region and then chase phantom `AccessDenied` errors.

### The test that proves it (`POST /chat` with a Cognito token)
```
"what is a firewall?"                          -> {"status":"ok","answer":...}   (allowed)
"Ignore all previous instructions and ..."     -> {"status":"blocked", ...}      (injection)
"My SSN is 123-45-6789 ..."                     -> {"status":"blocked", ...}      (PII)
```

### Alternatives considered
- **Inline guardrail (chosen)** vs **separate `ApplyGuardrail` call**. Inline =
  attach the guardrail to the `Converse` call; AWS checks input+output in one shot,
  fewest moving parts. Separate = call `ApplyGuardrail` first, decide block/allow
  yourself, then call the model — more control, more code. Chose inline now; the
  guardrail object is identical either way, so upgrading in Phase 6 (for alerting)
  is just splitting one call into two — no infra change.
- **Claude Sonnet / Nova** instead of Haiku — Sonnet is smarter but ~10–15× the cost;
  overkill for testing plumbing. Haiku chosen for cost; swapping later is one env var.
- **Bare model ID** instead of the `us.` inference profile — fails, because this model
  is on-demand *only* via a cross-region profile.
- **`Resource = "*"`** on the Bedrock policy — simpler, but violates least privilege.
  Rejected: scoped to exactly one model family + one guardrail.

### Memory Tricks (Phase 5)
- "**The model talks; the guardrail only judges.**" One generates, the others inspect.
- "**Injection is a punch thrown at the model, not by it**" — so PROMPT_ATTACK is
  input-only (`output_strength = NONE`).
- "**ANONYMIZE = black out the word and continue; BLOCK = stop the whole request.**"
- "**The profile picks the city at random, so hand a key to every city it might pick.**"
  (cross-region IAM)
- "**Profile is yours (has your account #); the model is AWS's (empty `::`).**"
- "**DRAFT is the Google Doc you're editing; a version is the PDF you shipped.**"
- "**Inference = the model running once to give one answer.**"
- "**Guardrail = a team of small ML classifiers + a few exact-match rules** (regex /
  word lists) — judges, never the answer-er."

### Doubts I Asked (Q&A)
- *Where is `output_strength = "NONE"` written?* In the **6th/last** `filters_config`
  block of `content_policy_config` — the `PROMPT_ATTACK` one. It's the only block not
  set to `"HIGH"`.
- *Why `NONE` on PROMPT_ATTACK but `HIGH` elsewhere?* Prompt injection is something a
  *user* does *to* the model — it only exists on the input. There's nothing to check on
  the output, and AWS rejects the filter if you set an output strength.
- *How do guardrails identify hate/insult/etc.?* Each category is its own **ML
  classifier** trained on labelled examples; it scores text by *meaning*, not a
  banned-word list, and `input_strength` is just where you set the confidence cut-off.
  That's why it catches paraphrases and misspellings a word list would miss — but it's
  probabilistic, so it can false-positive/negative (hence logging + alerts in Phase 6).
- *So a guardrail is kind of a machine-learning model?* Yes — a **bundle** of small
  pre-trained ML classifiers (toxicity, PII, injection) plus a couple of non-ML pieces
  (your regex + word lists). You don't write the detection; you switch classifiers on/
  off and set sensitivity. They judge; Claude is the one that answers.
- *What does "inference type" mean?* "Inference" = the model running once to produce an
  answer. "Inference type" = *how/where* AWS runs it: **on-demand (single region)** vs
  **cross-region inference** (any of several US regions, AWS's choice → needs the `us.`
  profile). Our Haiku page said cross-region, which drove both the profile ID and the
  multi-region IAM.
- *Why does cross-region inference force multi-region IAM?* AWS may route the request
  to any allowed US region, and model permission is granted per region. Permit only one
  region and you get random `AccessDenied` whenever AWS routes elsewhere. Fix: permit
  the model in every destination region.
- *Explain the cross-region gotcha simply, and where/what did we change in IAM?*
  Vending-machine analogy: the model is one snack sold in 3 cities; the inference
  profile randomly picks the city; each city's machine needs its own key card
  (per-region permission). One card = random `AccessDenied`; all three cards = always
  works. **Where/what:** in `terraform/bedrock.tf`, the `aws_iam_role_policy
  "lambda_bedrock"` block — its `Resource` list holds the profile ARN (yours, has the
  account #) plus the **foundation-model ARN for each of us-east-1/-2 and us-west-2**
  (AWS's, empty `::`). The three per-city model lines are the part people forget.
- *What is the "provider produced inconsistent final plan" bug?* Three layers:
  **Terraform** (the engine/project manager), the **AWS provider** (the plugin/
  translator that calls AWS), and **AWS** itself. The error named the *provider*: it
  predicted the Lambda would have 0 `environment` blocks, then changed to 1 mid-apply
  (because the guardrail didn't exist yet at plan time). Terraform's safety check
  ("plan must match reality") aborted. Fix: just **re-run `apply`** — now the guardrail
  exists, the values are concrete, and the counts line up. Not our code's fault.
- *Why did the token command fail with `--auth-flow: command not found`?* The `\`
  line-continuations broke on paste (a stray space after `\` escapes the space, not the
  newline), so each flag ran as its own command. Fix: put it on **one line**.
- *Why `bash: !: event not found`?* The `!` in the password triggers bash **history
  expansion**. Wrap the value in **single quotes** (`'...'`) to take every character
  literally.

---

---

## Phase 6 — Observability & Alerting (the logbook + the alarm bell)

### What we built (and why)
Up to now the guard *acted* (blocked attacks) but never *told anyone*. Phase 6 adds
the security desk's **logbook** and **alarm bell**: every request is written down as
a structured, redacted note, and the moment the guardrail blocks an attack, an email
lands in our inbox. Build order: log honestly → count the bad notes → alarm on the
count → email. **Detection lives in infrastructure, not app code** — so we can re-tune
alerting later without redeploying the Lambda.

### The chain (one blocked attack → one email)
```
Lambda logs {"event":"GUARDRAIL_BLOCK"}   <- STEP 1 (the only CODE)
        v
CloudWatch Logs stores the line           <- existing log group (Phase 3)
        v
Metric filter sees the label, +1 a metric <- STEP 3
        v
CloudWatch alarm: Sum>0 in 60s -> ALARM   <- STEP 3
        v
SNS topic -> email to me                  <- STEP 2
```
The whole relay hinges on **one exact word**: the filter pattern must match the label
the code writes — `GUARDRAIL_BLOCK`. One typo on either side and no email ever comes.

### The pieces (Terraform -> AWS)
- `src/handler.py` — added a `_log(event_type, request_id, **fields)` helper that emits
  **one JSON line per request**, metadata only (`prompt_length`, never the prompt). The
  block path emits `{"event": "GUARDRAIL_BLOCK", ...}` — the hook the filter matches.
- `aws_sns_topic "alerts"` — the notification **channel** (a megaphone).
- `aws_sns_topic_subscription "email"` — wires my inbox to the topic. Email subs start
  as `PendingConfirmation`; **AWS emails a confirm link I must click** (anti-spam) or it
  silently drops every alert.
- `aws_cloudwatch_log_metric_filter "guardrail_block"` — attached to the Lambda log
  group; JSON pattern `{ $.event = "GUARDRAIL_BLOCK" }` turns matching log lines into a
  `+1` on the `GuardrailBlocks` metric (namespace `SecureGenAIGateway`). `default_value
  = "0"` keeps the metric continuous so the alarm evaluates cleanly.
- `aws_cloudwatch_metric_alarm "guardrail_block"` — watches that metric: `Sum` over a
  `period = 60` window, `evaluation_periods = 1`, `threshold = 0`, `GreaterThanThreshold`
  → fires on the **first** minute with any block. `treat_missing_data = "notBreaching"`
  keeps it calm when idle. `alarm_actions = [topic.arn]` → publishes → email.

### The three joins that must line up (the failure points)
```
code label   "GUARDRAIL_BLOCK"  ==  filter pattern  $.event = "GUARDRAIL_BLOCK"
filter metric name/namespace    ==  alarm metric_name / namespace
alarm alarm_actions             ==  the SNS topic ARN
```
If the relay is silent, suspect one of these three before anything else.

### Lambda is BEFORE the guardrail — and it CALLS the guardrail
A point that confused me: the guardrail isn't a separate hop the user reaches on their
own. The request hits **Lambda first**; Lambda then calls Bedrock *with* `guardrailConfig`
attached, and Bedrock runs guardrail-in → model → guardrail-out and hands the verdict
**back to Lambda**. That's *why* only Lambda can write the `GUARDRAIL_BLOCK` note — it's
the only thing that sees the verdict. Security bonus: since the **only** path to the
model is through Lambda, and Lambda always attaches the guardrail, no caller can reach
the model while skipping the filter.

### The bucket-and-marbles model of the alarm (explain-like-I'm-14)
- `period = 60` — each **bucket** holds one minute of marbles; one marble per blocked
  attack. Fresh empty bucket every minute.
- `statistic = "Sum"` — count the marbles in the bucket.
- `evaluation_periods = 1` — **one** bad bucket is enough to yell (no "wait and see").
- `threshold = 0` + `GreaterThanThreshold` — a bucket with even one marble = yell.
- Read together: *"Every minute, count the blocked attacks; the first minute with even
  one → ring the bell."* Security wants `1`, not "3 in a row," because an attacker at the
  door is never a fluke.

### Alarm behavior that surprises everyone
The alarm emails on the **transition** OK→ALARM, **not once per attack**. Three blocks in
one minute = **one** email. To get a *second* email the metric must drop to 0 for a window
(alarm returns to OK), then breach again. *"The bell rings when the fire starts, not once
per flame."* This is the decoupling paying off — no email storm during an attack flood.

### The golden rule of security logging
**Log enough to investigate, never enough to leak.** The prompt may contain the exact
SSN/secret the guardrail exists to catch — so we log its *length*, never its *contents*.
If logging stays redacted, CloudWatch is a safe audit trail; the day someone "just
temporarily" logs the raw prompt to debug, the logbook becomes the breach.

### The test that proves it
```
normal prompt ("capital of France?")  -> 200 {"status":"ok"}      -> NO email   (quiet when fine)
injection ("ignore all instructions") -> 200 {"status":"blocked"} -> email in ~1-3 min
```
Also saw the auth layer work mid-test: an expired ID token returned `401 ... the token
has expired` from the JWT authorizer **before Lambda ran** — re-mint with `initiate-auth`.

### Alternatives considered
- **Metric filter + alarm + SNS (chosen)** vs **Lambda publishes to SNS directly.**
  Direct-publish is simpler and instant (an email per block, seconds) but bakes alerting
  into app code, needs an `sns:Publish` IAM grant, gives no reusable metric/graph, and
  floods you during an attack burst. The filter/alarm path decouples detection from the
  app, yields a tunable metric + dashboard, and de-dupes bursts into one alarm — the way
  a real security team builds it. Trade-off accepted: ~1-2 min latency.
- **KMS-encrypting the SNS topic** — deferred. Our alerts are metadata-only (no PII), and
  the *free* option (`alias/aws/sns`, the AWS-managed key) actually **breaks** CloudWatch
  alarm delivery (its key policy doesn't let CloudWatch publish). Proper encryption needs
  a **customer-managed** KMS key with a policy granting `cloudwatch.amazonaws.com`.
  Flagged as a Phase 7 hardening item, not worth derailing the pipeline now.
- **Capturing the blocked category** (PROMPT_ATTACK vs PII vs toxicity) via guardrail
  `trace` — richer "attack patterns," but adds parsing + more verbose logs. Deferred to a
  Phase 6.5 polish once the core pipeline is proven.

### Memory Tricks (Phase 6)
- "**Log enough to investigate, never enough to leak.**" (length, not contents)
- "**One word holds the whole chain together:** the filter must match the code's label,
  `GUARDRAIL_BLOCK`."
- "**Only the top box is code; the rest is wiring you can re-tune later.**"
- "**Bucket per minute, marble per attack; first bucket with a marble → ring the bell.**"
- "**The bell rings when the fire starts, not once per flame.**" (alarm = transition)
- "**SNS is a megaphone: build the channel once, plug in listeners later.**"
- "**Confirm the email or the alarm shouts into the void.**" (PendingConfirmation)
- "**Lambda is before the guardrail and it's the one holding the X-ray remote.**"

### Doubts I Asked (Q&A)
- *Is the Lambda before or after the guardrail?* **Before — and it calls the guardrail.**
  The request reaches Lambda first; Lambda calls Bedrock with `guardrailConfig`, Bedrock
  runs guardrail→model→guardrail and returns the verdict to Lambda. The guardrail is
  wrapped *inside* Lambda's Bedrock call, not a separate door. That's why only Lambda can
  log the block, and why no caller can reach the model while skipping the filter.
- *What do `statistic`/`period`/`evaluation_periods`/`threshold` mean?* They define
  "what counts as bad enough to alarm." Sum = add the per-window counts; period = the
  window size (60s buckets); evaluation_periods = how many bad windows in a row before
  ringing (1 = no second chances); threshold (with `GreaterThanThreshold`) = alarm when
  Sum > 0. Together: *"every 60s, add the blocks; one bad minute → ring."*
- *Explain `period`/`evaluation_periods` like I'm 14.* `period = 60`: a fresh bucket each
  minute, one marble per blocked attack. `evaluation_periods = 1`: a single bucket with
  any marble is enough to yell — no waiting to see if it keeps happening. (Set it to 3 to
  ignore brief blips, but for security you yell the first time.)
- *Why didn't my first `curl` print anything?* `$API_URL` was empty — env vars die with
  the terminal, and `-s` (silent) hid the failed request. Re-`export API_URL=...` from
  the `terraform output`, drop the trailing slash, and add `-i` to see the status line.
- *Why did I get 401 "the token has expired"?* Cognito ID tokens last ~1 hour; the JWT
  authorizer rejected the stale one **before Lambda ran** (the lock working). Re-mint with
  `aws cognito-idp initiate-auth ...`.
- *What was the problem with the tokens earlier — full story?* There were **two separate
  problems**, easy to confuse:
  1. **Blank curl output — NOT a token issue.** `$API_URL` was *empty* (env vars die with
     the terminal), so the request went nowhere, and `-s` (silent) hid the error. Fix:
     re-`export API_URL=...` (drop the trailing slash). Add `-i` to see the status line.
  2. **`401 ... the token has expired` — the real token issue.** The ID token is a paper
     **wristband** proving "this is me," stapled to every request via the `Authorization`
     header. It has an **expiry baked in** (the `exp` claim) — Cognito ID tokens last
     **~1 hour**. My `ID_TOKEN` was left over from an earlier session, so `exp` was in the
     past; the JWT authorizer (the bouncer) read it, saw it was stale, and bounced me
     **before Lambda ran**. Fix: re-mint a fresh token with `initiate-auth`.
  **Why expire on purpose (the security why):** short life limits the blast radius if a
  token leaks — a stolen wristband is useless within the hour, vs a never-expiring token
  that's a permanent skeleton key. The 401 was the system protecting me, not a bug. Memory
  trick: *"Wristband good for one hour; after that the bouncer tears it off — go back to the
  booth for a new one."* Upgrade for later (flagged): use the **refresh token** (longer-
  lived) to silently renew instead of re-sending username/password each hour; for CLI
  testing, just re-running `initiate-auth` is simpler.

---

## Phase 7 — CI/CD + Security Scanning (in progress)

> **Repo going public.** This repo will be linked from my resume, so it will be made
> **public**. That single fact reshaped the security design: the trust policy is pinned
> to my exact repo, and the rule "never commit a secret" goes from important to
> non-negotiable (a public repo exposes the *entire git history*, not just current
> files). Before going public we audited history + content — clean: no state, tfvars,
> `.env`, keys, or access-key patterns ever committed; account ID isn't even hardcoded;
> remote state lives in S3, never in git.

### 7a — OIDC authentication (no more long-lived keys)

#### What we built (and why)
We want a robot (GitHub Actions, coming in 7c) to run Terraform for us. The naive way is
to copy my IAM access keys into GitHub as secrets — a real pro refuses that instantly:
long-lived keys never expire, can leak, and must be rotated by hand. Instead we set up
**OIDC** so GitHub proves *who it is* and AWS hands back a **temporary ~1-hour badge**.
No secret is stored anywhere — nothing to leak, nothing to rotate.

#### The nightclub / passport model (explain-like-I'm-14)
```
GitHub Actions  --"I'm a workflow on Darsh's repo, here's my signed token"-->  AWS
                                                                                |
                          AWS checks its guest list (the trust policy)          |
                                                                                v
                                          hands back a 1-hour badge  <----------+
```
- **OIDC** = trusting an outside ID-issuer. We told AWS "accept passports from GitHub's
  passport office" (the identity provider) and wrote a guest list ("only `main` on *my*
  repo gets in").
- **No stored password** — trust is based on *identity* (which repo), not a *secret*.
- "**A door's address isn't a key**" — the role ARN is public-safe; you can't enter
  unless the guest list names your identity.

#### The pieces (Terraform → AWS), all in `terraform/oidc.tf`
- `aws_iam_openid_connect_provider.github` — registers GitHub's issuer
  (`https://token.actions.githubusercontent.com`) with audience `sts.amazonaws.com`.
  **No `thumbprint_list`** on purpose: since AWS provider v5+, AWS validates GitHub's
  TLS cert against its own trusted-CA library. Old tutorials hardcode a thumbprint —
  GitHub rotated it in 2023 and broke everyone. *Hardcoded fingerprints rot.*
- `aws_iam_role.github_actions` — the role GitHub assumes. Trust policy differs from the
  Lambda role in three ways:
  1. `Action = sts:AssumeRoleWithWebIdentity` (not `sts:AssumeRole`) — assumed by an
     outside web identity, not an AWS service.
  2. `Principal.Federated = <the OIDC provider ARN>` — "an identity from a trusted
     outside system."
  3. A `Condition` that *is* the security: `StringEquals` on `:aud = sts.amazonaws.com`
     AND `:sub = repo:savanidarsh/secure-genai-gateway:ref:refs/heads/main`. Exact match,
     no wildcard → a fork (which carries a *different* `sub`) is turned away at the door.
- `aws_iam_role_policy_attachment.github_actions_readonly` — AWS-managed `ReadOnlyAccess`.
- `aws_iam_role_policy.github_actions_state` (`tfstate-access`) — scoped Get/Put/Delete on
  the **state bucket** objects (for the plan lock) + ListBucket. Nothing else writable.

#### Why the pipeline role is READ-ONLY (the design decision)
The pipeline's job is `terraform plan` — a dry run that only *reads*. I keep running
`apply` by hand. Two reasons: (1) genuinely least-privilege — even if the pipeline were
abused it couldn't create/change/delete anything; (2) a role powerful enough to `apply`
must be able to create+attach IAM policies, and *anything that can do that can escalate
itself to admin* — so an "apply role" isn't really least-privilege anyway. Read-only
sidesteps that. The one apparent contradiction: even `plan` takes a short **state lock**
(a tiny file written then deleted in the state bucket), so the role needs Put/Delete —
but **only on that one bucket**. *Read the whole house; only allowed to scribble on the
one notepad.*

#### The test that proves it
```
terraform plan  -> Plan: 4 to add, 0 to change, 0 to destroy   (provider + role + 2 policies)
terraform apply -> Apply complete! Resources: 4 added
aws iam get-role --role-name secure-genai-gateway-github-actions
   -> Action = sts:AssumeRoleWithWebIdentity, :aud = sts.amazonaws.com,
      :sub = repo:savanidarsh/secure-genai-gateway:ref:refs/heads/main   (door correctly scoped)
```

#### Alternatives considered
- **Long-lived IAM access keys in GitHub secrets** — the common tutorial path. Rejected:
  never expire, leak-prone, manual rotation. OIDC's temporary badge is strictly better,
  *especially* for a public repo.
- **Hardcoded OIDC thumbprint** — brittle; GitHub rotated it once and broke thousands of
  pipelines. Omitted; AWS handles the CA.
- **Wildcard `sub` (`repo:owner/repo:*` or broader)** — convenient but too loose for a
  public repo. Pinned to exact repo + `main`. (Note: a fork's `sub` names the *fork's*
  repo, so even `:*` wouldn't grant forks — but exact-match is defense in depth.)
- **Admin / apply-capable CI role** — simplest, but over-privileged and, per the IAM
  escalation point above, not meaningfully least-privilege. Chose read-only + manual apply.
- **Gated apply job via a GitHub Environment + required-reviewer approval** — the clean
  "real" way to add apply later (the approval doubles as the manual gate). Flagged for 7c
  if I want auto-apply; not needed now.

#### Memory Tricks (Phase 7a)
- "**Temporary badge, not a permanent key.**" (OIDC vs stored access keys)
- "**Hardcoded fingerprints rot.**" (skip `thumbprint_list`)
- "**Federated = an ID from a trusted outside system; WebIdentity = it knocked holding a
  signed token.**"
- "**The token wears a name tag; we only let in `main` from *my* repo.**" (the `sub` claim)
- "**A door's address isn't a key.**" (role ARN is public-safe)
- "**Read the whole house; only scribble on the one notepad.**" (read-only + scoped state)
- "**Anything that can hand out IAM policies can crown itself admin.**" (why apply roles
  aren't really least-privilege)
- "**Public repo = the whole history is on display, not just today's files.**"

#### Doubts I Asked (Q&A)
- *Can I make the repo public now, and will it break anything?* Yes, safe to do anytime —
  it has **zero effect on the OIDC work** (the role didn't exist yet, and it's scoped to my
  repo regardless). The real risk isn't OIDC, it's **history**: going public exposes every
  past commit, so a secret committed and later deleted would still be visible. We audited
  first — history + content clean — so it's safe. New habit: `git status` / `git diff
  --staged` before every push now that it's public.
- *So we read the plan output, and only then apply?* Exactly. `terraform plan` = a dry run
  that changes nothing and prints a preview (read it like a receipt). `terraform apply` =
  the real build, and it re-shows the plan and makes you type `yes`. Rhythm: **plan → read
  it → apply only if it looks right.** The number that matters most is `0 to destroy`.
- *Is `aws_iam_role_policy_attachment...readonly` a separate step?* No — it's just **one of
  the four resources** `plan` lists (the one that attaches read-only power to the role), not
  a command of its own.

#### Phase 7a summary (the 5 things to remember)
1. OIDC swaps a **permanent stored key** for a **1-hour badge** — nothing to leak or rotate.
2. The **provider** says "trust GitHub's passport office"; the **role + trust policy** is
   the guest list ("`main` on *my* repo only").
3. The `Condition` (`aud` + exact `sub`) is the actual lock — without it, any repo could
   assume the role.
4. The CI role is **read-only** (plan only) + scoped state-bucket writes for the lock =
   least-privilege; I apply manually.
5. Skip the **thumbprint** (it rots); going **public** makes "never commit secrets" and
   tight scoping non-negotiable.

---

### 7b — Checkov security scanning

#### What we built (and why)
**Checkov** is a *static analysis* tool: it reads the `.tf` files (without building
anything) and checks them against 1000+ security rules. It's a **home inspector
reading the blueprints before the house goes up** — catching "no smoke detector"
on paper, where it's free to fix. The term for this is **"shift left"**: move
security checks to the *start* of the process, where flaws are cheap. In 7c this
scan becomes an automatic gate in the pipeline.

#### The mindset (the real lesson)
A finding is **not an order — it's a question**: *"did you mean to leave this off?"*
Every finding gets one of two honest answers:
1. **Fix it** — add the missing setting.
2. **Accept it** — decide it's not worth it *here*, and leave a signed note so it's
   a *decision*, not an oversight: `#checkov:skip=CKV_AWS_144:reason`. Next scan it
   shows as **Skipped** with the reason attached.
*"Negligent vs informed decision is one comment."* On a public repo this is gold —
a reviewer sees you weighed each risk.

#### Install gotcha (Windows + Python 3.14)
`pip install checkov` worked, but `checkov: command not found` — pip dropped
`checkov.exe` in a `Scripts/` dir not on Git Bash's PATH. Fix: add it to PATH and
persist in `~/.bashrc`:
```bash
export PATH="$PATH:/c/Users/savan/AppData/Local/Python/pythoncore-3.14-64/Scripts"
echo 'export PATH=...same...' >> ~/.bashrc   # permanent
```

#### The triage (20 findings → 4 fixed, 17 skipped, 0 failed)
First scan: **70 passed / 20 failed**. Chose the **balanced** approach: fix the
cheap high-value items, accept the rest with inline skips.

**Fixed (real security value, low effort):**
| Check | Fix | Why it matters |
|---|---|---|
| CKV_AWS_115 | Lambda `reserved_concurrent_executions = 10` | Circuit breaker: a flood can't spin up thousands of Lambdas → caps cost + blast radius |
| CKV_AWS_338 | log retention 14 → 365 days | A 3-week-old log is gone when you investigate; a year of tiny JSON lines is pennies |
| CKV_AWS_76 | API Gateway access logging → new log group | The API's "black box": every call (who/when/route/status), no prompt body |
| CKV_AWS_18 | state-bucket access logging → logs bucket **+ bucket policy** | Audit who touches state. **Gotcha:** the *destination* bucket must grant `logging.s3.amazonaws.com` permission or delivery silently fails |

**Accepted with inline skip (17):** grouped as —
- *Not applicable to this architecture:* DLQ (CKV_AWS_116, sync invoke), VPC
  (CKV_AWS_117, only calls public Bedrock), event-notifications (CKV2_AWS_62),
  cross-region replication (CKV_AWS_144, DR out of scope), code-signing
  (CKV_AWS_272, enterprise supply-chain).
- *Already mitigated / defensible trade-off:* S3 + log-group + env-var KMS
  (CKV_AWS_145/158/173 — already AES256 at rest, data is non-secret), lifecycle
  (CKV2_AWS_61, cost-hygiene not security), logs-bucket self-logging (CKV_AWS_18),
  SNS encryption (CKV_AWS_26 — AWS-managed key breaks alarm delivery; real fix =
  customer-managed KMS key with a policy allowing `cloudwatch.amazonaws.com`).

Re-scan: **78 passed / 0 failed / 17 skipped.**

#### Memory Tricks (Phase 7b)
- "**Checkov = a home inspector reading the blueprints before the house is built.**"
- "**Shift left = catch it cheap, at the start.**"
- "**A finding is a question, not an order — fix it or sign for it.**"
- "**`#checkov:skip=ID:reason` turns 'we missed it' into 'we decided'.**"
- "**Reserved concurrency = a circuit breaker on a flood.**"
- "**A log you can't look back far enough on isn't an audit trail.**"
- "**Turning on logging isn't enough — the destination must agree to receive it.**"
- "**Encrypted-at-rest (AES256) already passes the spirit; KMS is about key *control*, which costs.**"

#### Doubts I Asked (Q&A)
- *Won't all these skips look like I'm dodging security?* The opposite — an
  unexplained gap looks negligent; a `#checkov:skip` with a reason proves you
  considered the risk and made a call. The danger is skipping *without* a reason.
- *Why fix retention but skip KMS?* Retention is cheap and has real forensic value;
  KMS (customer-managed keys) adds ~$1/key/mo + key management for data that's
  already encrypted at rest and isn't secret. Cost/benefit, decided per-item.
- *Why did the parser fail in the sandbox but not on my machine?* My helper's HCL
  parser was older than the one your `checkov` shipped with; newer parser handled
  all files. Lesson: a "parsing error" can be a tooling-version issue, not your code.

#### Phase 7b summary (the 5 things to remember)
1. Checkov reads your `.tf` and flags insecure config **before** anything is built
   ("shift left").
2. Each finding = **fix it** or **accept it with a signed `#checkov:skip` reason** —
   never an unexplained gap.
3. The fixes worth making here: **concurrency cap, 1-yr retention, API + state
   access logging** (real security value, low effort/cost).
4. The accepts: KMS/VPC/DLQ/replication/etc. — already-mitigated or N/A for this
   architecture; documented, not ignored.
5. End state: **0 failed**, 17 justified skips — and a re-scan you can wire into CI
   in 7c to block any *new* insecure config.

---

### 7c — GitHub Actions pipeline (CI/CD)

#### What we built (and why)
A **GitHub Actions** workflow — a robot that runs automatically on every push to
`main`. Two jobs: (1) **Checkov** scans the Terraform (the security gate), and
(2) **terraform plan** assumes the 7a OIDC role and shows what would change. Job 2
only runs if job 1 passed (`needs:`). Security gates the deploy. Vocabulary:
*workflow* = the recipe (a YAML file in `.github/workflows/`); *job* = steps on a
fresh throwaway machine (*runner*); *step* = one command (`run:`) or reusable
*action* (`uses:`). **YAML is indentation-sensitive like Python** — 2 spaces, no tabs.

#### Why this exact shape (it fits the 7a trust policy)
The OIDC role is pinned to `ref:refs/heads/main`. So:
- **Checkov needs no AWS** (it only reads files) → runs on every push *and* PR.
- **terraform plan needs AWS** → runs only on push to `main` (`if:
  github.event_name == 'push'`), where the token's `sub` matches the trust policy.
  Trying it on a PR would just fail the auth, so we don't.
Since I commit straight to `main`, the plan job fires on every push — no Terraform
change needed.

#### Three things that make OIDC work in the workflow
1. `permissions: id-token: write` on the plan job — **the line everyone forgets.**
   Without it GitHub won't mint the token and `configure-aws-credentials` fails
   with "Could not load credentials." It's the switch that lets the job hold up
   its passport. Only that one job has it (least privilege).
2. `role-to-assume: ${{ secrets.AWS_ROLE_ARN }}` — the role ARN, stored as a repo
   **secret** (not because an ARN is sensitive — it isn't a credential — but to
   keep the account number out of public workflow code).
3. **No AWS key anywhere in the file.** Temporary creds are minted per run, gone in
   ~1 hour. 7a paying off.

#### The bug we hit (a great real lesson)
First run: **Checkov green, plan red.** OIDC *worked* (the error came from
`assumed-role/secure-genai-gateway-github-actions/GitHubActions` — we were already
authenticated). Plan refreshed all 25 resources, then died on **one** action:
```
AccessDeniedException: not authorized to perform: bedrock:ListTagsForResource
```
AWS-managed **`ReadOnlyAccess` is broad but not complete** — it omits some newer
read actions (here, reading the guardrail's tags during refresh). Fix = the *right*
least-privilege move: grant the **one** missing read, scoped to our guardrail —
not "give it more access." Added `aws_iam_role_policy.github_actions_bedrock_read`
to `oidc.tf`.

**Chicken-and-egg:** the CI role is read-only — it *can't grant itself* IAM
permissions. So a human with admin creds runs `terraform apply` locally to add the
permission. (That same apply also deployed the still-pending 7b hardening.) Then
push → CI re-runs → **both jobs green**, plan reports no changes (CI confirming live
AWS matches the code).

#### Memory Tricks (Phase 7c)
- "**A workflow is a recipe card pinned to the fridge: when X happens, do these steps.**"
- "**Checkov needs no passport (reads files); plan needs one (touches AWS).**"
- "**`id-token: write` = permission to hold up your passport** — forget it and OIDC dies."
- "**Security gates the deploy:** `needs: checkov` — no scan pass, no plan."
- "**ReadOnlyAccess is broad, not total** — grant the one missing read, scoped."
- "**A read-only role can't widen itself** — a human with more power applies that change.**"
- "**Green plan with 'no changes' = CI confirming reality matches the code.**"

#### Doubts I Asked (Q&A)
- *The plan job failed — did OIDC break?* No — the error was raised *as the assumed
  role*, so auth succeeded. It failed later on a missing read permission. Read *who*
  the error is about: it was already "assumed-role/…/GitHubActions".
- *Why not just give the CI role broader Bedrock/admin access to make it work?*
  That throws away least privilege. The fix is the single missing **read** action,
  scoped to the guardrail. Stay narrow on purpose.
- *Why did I have to apply locally instead of letting CI do it?* The CI role is
  read-only by design — it can't create IAM policies (and shouldn't; a role that can
  attach IAM policies can escalate to admin). Privileged changes are a human step.

#### Phase 7c summary (the 5 things to remember)
1. The pipeline = **Checkov gate** + **terraform plan via OIDC**, plan `needs:` the
   scan to pass first.
2. `id-token: write` is mandatory for OIDC; the role ARN rides in a **secret**; **no
   AWS keys** live in the repo.
3. The plan job runs **on push to `main`** because that's what the OIDC trust policy
   allows; Checkov (no AWS) runs everywhere.
4. `ReadOnlyAccess` missed `bedrock:ListTagsForResource` — fixed with a **scoped,
   single-action** grant, not broader access.
5. A **read-only CI role can't widen its own permissions** — a human applies that;
   then CI goes green and confirms live infra matches code.

---

*(Phase 7 complete. The gateway now authenticates, inspects, blocks/redacts, logs,
alerts, AND ships through a scanned, keyless CI/CD pipeline. Possible next: a gated
apply job (GitHub Environment + approval), the deferred SNS CMK, or capturing the
blocked guardrail category — all optional hardening.)*
