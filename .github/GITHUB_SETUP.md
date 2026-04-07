# GitHub configuration

## CI

Workflow [`.github/workflows/ci.yml`](workflows/ci.yml) runs **`swift test`** on **macOS 15** with Swift **6.1** on every push and pull request to **`main`** and **`develop`**.

## Branch protection (git-flow)

Target setup:

| Branch | Merge via | CI |
|--------|-----------|-----|
| **`develop`** | Pull request only | Required: **Swift PM** |
| **`main`** | Pull request only (releases from `develop`) | Required: **Swift PM** |

### Personal private repo on GitHub **Free**

The REST API for **branch protection** and **repository rulesets** returns **403** on private repos owned by personal accounts unless you have **GitHub Pro** (or the repo is public). Apply rules in the web UI:

1. **Settings → Rules → Rulesets** (or **Branches → Branch protection rules** for classic rules).
2. Add a ruleset (or rule) for **`main`**:
   - Require a **pull request** before merging.
   - Require status check **Swift PM** (from workflow **CI**), strict where offered.
3. Repeat for **`develop`** with the same requirements.

After at least one CI run, the **Swift PM** check appears in the “required checks” dropdown.

### GitHub Pro / public repo / organization

You can create the same **ruleset** via API using [`.github/ruleset-protect-branches.json`](ruleset-protect-branches.json):

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
