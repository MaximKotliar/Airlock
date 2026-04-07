## Summary

<!-- What does this PR change and why? -->

## Base branch

Git flow for this repo:

| Change type | Target branch |
|-------------|---------------|
| Features / fixes / chores | **`develop`** |
| Release (promote tested work to production default branch) | **`main`** (open a PR from **`develop` → `main`**) |

- [ ] This PR targets **`develop`** (normal work)
- [ ] This PR targets **`main`** (release: merge **`develop` into `main`** only)

## Checklist

- [ ] **CI** check **Swift PM** is green on this PR (required for merge once branch protection is enabled — see [GITHUB_SETUP.md](.github/GITHUB_SETUP.md))
- [ ] `swift test` passes locally
- [ ] README / public API updated if needed

## Related

<!-- Issues, prior discussion, etc. -->
