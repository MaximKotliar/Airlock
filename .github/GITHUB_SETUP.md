# GitHub configuration

## CI

Workflow [`.github/workflows/ci.yml`](workflows/ci.yml) runs **`swift test`** on **`macos-latest`** with **`xcode-select`** set to **Xcode 26.3** on every push and pull request to **`main`** and **`develop`**.

The check name reported to GitHub is **`Swift PM`** (job name in the workflow). **PRs should not merge until this check passes.**

## Require tests before PR merge (status checks)

Enable this for **`main`** and **`develop`**. After CI has run at least once on each branch, **Swift PM** appears when you add required checks.

### Option A — Repository rulesets (Settings → Rules → Rulesets)

1. Open **Settings → Code and automation → Rules → Rulesets**.
2. **New ruleset → New branch ruleset**.
3. **Ruleset name:** e.g. `require-ci-main-develop`.
4. **Bypass list:** leave empty (or add only break-glass actors).
5. **Enforcement status:** **Active**.
6. **Target branches → Add target → Include by pattern** (repeat as needed):
   - `main`
   - `develop`  
   Or use one pattern that matches both if your UI supports it (e.g. two inclusion rows).
7. Under **Branch rules**, add:
   - **Require a pull request before merging** — enable (set approving reviews to **0** if you do not want mandatory reviewers).
   - **Require status checks to pass** — enable:
     - Turn on **Require branches to be up to date before merging** (so the PR branch must include the latest base + green CI).
     - **Add checks** → search **`Swift PM`** → add it (source is workflow **CI** / GitHub Actions).
8. **Create** (or **Save**) the ruleset.

If the UI only allows one branch pattern per ruleset, create **two rulesets** (one for `main`, one for `develop`) with the same rules.

### Option B — Classic branch protection (Settings → Branches)

1. **Settings → Code and automation → Branches**.
2. **Add branch protection rule**.
3. **Branch name pattern:** `main` → Add rule.
4. Enable:
   - **Require a pull request before merging** (optional: require approvals).
   - **Require status checks to pass before merging**
     - **Require branches to be up to date before merging**
     - In **Status checks that are required**, add **`Swift PM`**.
5. Save, then repeat with branch name pattern **`develop`**.

### Verify

Open a test PR into `develop` (or `main`). The merge button should stay disabled (or warn) until **Swift PM** is green. If the check is missing from the picker, push a commit to that branch and wait for **CI** to finish once.

## Branch protection (git-flow summary)

| Branch | Merge via | CI |
|--------|-----------|-----|
| **`develop`** | Pull request only | Required: **Swift PM** |
| **`main`** | Pull request only (releases from `develop`) | Required: **Swift PM** |

## Personal private repo on GitHub **Free** — API limitation

The REST API for **branch protection** and **repository rulesets** often returns **403** on private repos owned by personal accounts unless you have **GitHub Pro** (or the repo is public). Use the **web UI** steps above.

## GitHub Pro / public repo / organization — API

Create the same **ruleset** via API using [`.github/ruleset-protect-branches.json`](ruleset-protect-branches.json):

```bash
gh api repos/<owner>/<repo>/rulesets --method POST --input .github/ruleset-protect-branches.json
```

If your check name or GitHub App id differs, edit the JSON (`context`: **Swift PM**, `integration_id`: **15368** is GitHub Actions).

Classic branch protection:

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input branch-protection-body.json
```

(use the same `required_status_checks.checks` entry for **Swift PM** / app id **15368**).

## Branches

- **`main`** and **`develop`** exist on the remote.
- Default branch stays **`main`**; day-to-day work merges into **`develop`**.

See [BRANCHING.md](BRANCHING.md) for the full flow.
