# branch-resolver

GitHub action that determines, for each dependency repository, the commit
that matches the branch stack of the event that triggered the workflow
(feature → integration → master). Replaces the practice of checking out a
dependency branch by name, which breaks when a parent branch advances, is
rebased or shares its name across repositories.

## Usage

```yaml
- uses: actions/checkout@v6
  with:
    fetch-depth: 0          # required: the resolver reads origin refs

- uses: specs-feup/branch-resolver@v1
  with:
    source-directory: clava
    dependencies: |
      lara specs-feup/lara-framework
      specs specs-feup/specs-java-libs
  # evidence-repositories: specs-feup/clava
  # integration-branch: staging
  # root-branch: master

- uses: actions/checkout@v6
  with:
    repository: specs-feup/lara-framework
    ref: ${{ env.lara_ref }}
```

## Inputs

| Input | Required | Description |
|---|---|---|
| `source-directory` | yes | Path to the checked-out source repository (needs `fetch-depth: 0`) |
| `dependencies` | yes | Whitespace/newline-separated `output-prefix repository` pairs; repository is `owner/name`, a URL or a local path |
| `source-branch` | no | Branch being tested; defaults to `github.head_ref \|\| github.ref_name` |
| `integration-branch` | no | Integration branch name; defaults to `staging` |
| `root-branch` | no | Root branch name; defaults to `master` |
| `evidence-repositories` | no | Extra repos consulted as ordering evidence |
| `github-token` | no | Token for reading open PRs; defaults to `github.token` |

## How it works

Ordering evidence is resolved **per repository**: the same branch names can
stack in opposite orders in different repositories (for example after a
rebase), so a dependency is ordered only by its own content. The resolver
collects the stack levels at or below the event commit in the source
repository, then pins each dependency to the first of its own branches that
contains all of those levels. Levels the source's history cannot prove
(e.g. a parent rebased without a merge commit) are taken from the source's
open PR base chain when available; nothing else depends on PR metadata.
The source branch's own name never shadows a same-named branch in a
dependency — each candidate must actually contain the required levels.
When no dependency branch covers the required levels, the resolver fails
with an ambiguity error rather than guessing.

## Outputs

For every dependency prefix the action exports environment variables
(through `GITHUB_ENV`):

- `<prefix>_ref` — commit SHA to check out
- `<prefix>_branch` — the resolved branch name
- `<prefix>_default` — the dependency repository's default branch

To pass them to another job, map them to job outputs:

```yaml
jobs:
  build:
    outputs:
      lara_ref: ${{ env.lara_ref }}
```

## Versioning

CI runs the resolver test suite plus a self-test that exercises the action
end-to-end. Pin `@v1` for consumers; move to `@v2` only on breaking changes.
