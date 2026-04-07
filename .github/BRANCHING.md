# Branching model

This repo uses a **git-flow style** workflow:

1. **`main`** — default, production-ready history. **Do not push directly.** Merge only via PR (typically from `develop` when cutting a release).
2. **`develop`** — integration branch. Open PRs **into `develop`** for day-to-day features and fixes.
3. **Feature branches** — `feature/…`, `fix/…`, etc., branched from **`develop`**, merged back via PR to **`develop`**.
4. **Releases** — When `develop` is ready, open **`develop` → `main`** and merge after review.

**Configure protection on GitHub** (required PRs + CI for `main` and `develop`). On **GitHub Free private** personal repos, use the **Settings → Rules** UI—see [GITHUB_SETUP.md](GITHUB_SETUP.md). With **Pro** or a **public** repo, you can apply [ruleset-protect-branches.json](ruleset-protect-branches.json) via `gh api`.

```text
feature/foo ──PR──► develop ──PR (release)──► main
```

Local quickstart:

```bash
git fetch origin
git checkout develop
git pull
git checkout -b feature/my-change
# … commit …
git push -u origin feature/my-change
# Open PR: base = develop
```

Release:

```bash
# Open PR: base = main, compare = develop
```
