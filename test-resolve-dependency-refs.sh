#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
resolver=${1:-"${script_directory}/resolve-dependency-refs.sh"}
test_directory=$(mktemp -d)
source_repository="${test_directory}/source"

git init --quiet --initial-branch=master "$source_repository"
git -C "$source_repository" config user.name "CI Resolver Test"
git -C "$source_repository" config user.email "ci-resolver@example.invalid"

commit() {
  local message=$1
  git -C "$source_repository" commit --quiet --allow-empty -m "$message"
}

commit "master base"

git -C "$source_repository" switch --quiet -c staging
commit "staging base"

git -C "$source_repository" switch --quiet -c lmsousa
commit "branch A"
lmsousa_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet -c vitest
commit "branch B"
vitest_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet -c java-deprecation
commit "branch C"
java_deprecation_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet -c workflow-fix
commit "current branch"
workflow_fix_tip=$(git -C "$source_repository" rev-parse HEAD)

# Both long-lived branches advance after the stack was created.
git -C "$source_repository" switch --quiet staging
commit "advanced staging"
staging_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet master
commit "advanced master"
master_tip=$(git -C "$source_repository" rev-parse HEAD)

# Simulate a later push after the workflow event was created. Resolution must
# use the detached event commit, never the newer remote source branch tip.
git -C "$source_repository" switch --quiet workflow-fix
commit "post-event parent branch"
later_parent_tip=$(git -C "$source_repository" rev-parse HEAD)
git -C "$source_repository" branch later-parent
commit "post-event source update"
post_event_source_tip=$(git -C "$source_repository" rev-parse HEAD)
git -C "$source_repository" switch --quiet --detach "$workflow_fix_tip"

git -C "$source_repository" switch --quiet lmsousa
commit "advanced parent branch"
advanced_lmsousa_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet staging
git -C "$source_repository" switch --quiet -c rebased-parent-fixture
commit "rebased parent branch"
rebased_lmsousa_tip=$(git -C "$source_repository" rev-parse HEAD)

git -C "$source_repository" switch --quiet --detach "$lmsousa_tip"
git -C "$source_repository" switch --quiet -c unrelated-sibling
commit "unrelated sibling branch"
unrelated_sibling_tip=$(git -C "$source_repository" rev-parse HEAD)
git -C "$source_repository" switch --quiet --detach "$workflow_fix_tip"

for branch in workflow-fix java-deprecation vitest lmsousa staging master; do
  branch_variable=${branch//-/_}_tip
  git -C "$source_repository" update-ref \
    "refs/remotes/origin/${branch}" "${!branch_variable}"
done
git -C "$source_repository" update-ref \
  refs/remotes/origin/workflow-fix "$post_event_source_tip"
git -C "$source_repository" update-ref \
  refs/remotes/origin/later-parent "$later_parent_tip"
# Clava's vitest and java-deprecation refs are intentionally equal. Another
# repository must provide their strict ordering.
git -C "$source_repository" update-ref \
  refs/remotes/origin/vitest "$java_deprecation_tip"

make_dependency() {
  local name=$1
  shift
  local repository="${test_directory}/${name}.git"

  git clone --quiet --bare "$source_repository" "$repository"
  while IFS= read -r ref; do
    git -C "$repository" update-ref -d "$ref"
  done < <(git -C "$repository" for-each-ref --format='%(refname)' refs/heads)

  git -C "$repository" update-ref refs/heads/master "$master_tip"
  for branch in "$@"; do
    branch_variable=${branch//-/_}_tip
    git -C "$repository" update-ref "refs/heads/${branch}" "${!branch_variable}"
  done
  git -C "$repository" symbolic-ref HEAD refs/heads/master
  echo "$repository"
}

current_dependency=$(make_dependency current workflow-fix lmsousa)
middle_dependency=$(make_dependency middle java-deprecation vitest lmsousa)
older_dependency=$(make_dependency older vitest lmsousa)
integration_dependency=$(make_dependency integration staging)
root_dependency=$(make_dependency root)
equal_dependency=$(make_dependency equal java-deprecation vitest lmsousa)
git -C "$equal_dependency" update-ref \
  refs/heads/vitest "$java_deprecation_tip"
ambiguous_dependency=$(make_dependency ambiguous java-deprecation vitest lmsousa)
git -C "$ambiguous_dependency" update-ref \
  refs/heads/vitest "$staging_tip"
reverse_dependency=$(make_dependency reverse java-deprecation vitest lmsousa)
git -C "$reverse_dependency" update-ref \
  refs/heads/java-deprecation "$vitest_tip"
git -C "$reverse_dependency" update-ref \
  refs/heads/vitest "$java_deprecation_tip"
advanced_dependency=$(make_dependency advanced lmsousa staging)
git -C "$advanced_dependency" update-ref \
  refs/heads/lmsousa "$advanced_lmsousa_tip"
rebased_dependency=$(make_dependency rebased lmsousa staging)
git -C "$rebased_dependency" update-ref \
  refs/heads/lmsousa "$rebased_lmsousa_tip"
sibling_dependency=$(make_dependency sibling unrelated-sibling staging)

output_file="${test_directory}/github-output"
log_file="${test_directory}/resolver.log"
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="$output_file" \
  bash "$resolver" "$source_repository" \
    current "$current_dependency" \
    middle "$middle_dependency" \
    older "$older_dependency" \
    integration "$integration_dependency" \
    root "$root_dependency" |
  tee "$log_file"

grep -Fqx \
  "Dependency branch candidates: workflow-fix -> java-deprecation -> vitest -> lmsousa -> staging -> master" \
  "$log_file"
if grep -Fq "later-parent" "$log_file"; then
  echo "Resolver used a branch created after the workflow event" >&2
  exit 1
fi
grep -Fqx "current_branch=workflow-fix" "$output_file"
grep -Fqx "current_ref=${workflow_fix_tip}" "$output_file"
grep -Fqx "middle_branch=java-deprecation" "$output_file"
grep -Fqx "middle_ref=${java_deprecation_tip}" "$output_file"
grep -Fqx "older_branch=vitest" "$output_file"
grep -Fqx "older_ref=${vitest_tip}" "$output_file"
grep -Fqx "integration_branch=staging" "$output_file"
grep -Fqx "integration_ref=${staging_tip}" "$output_file"
grep -Fqx "root_branch=master" "$output_file"
grep -Fqx "root_ref=${master_tip}" "$output_file"

# Equal, unordered names are safe when they resolve to the same target commit.
equal_output="${test_directory}/equal-output"
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="$equal_output" \
  bash "$resolver" "$source_repository" \
    equal "$equal_dependency" >/dev/null
grep -Fqx "equal_ref=${java_deprecation_tip}" "$equal_output"

# Diverged candidates with no ordering evidence must fail rather than guess.
if SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/ambiguous-output" \
  bash "$resolver" "$source_repository" \
    ambiguous "$ambiguous_dependency" \
    >"${test_directory}/ambiguous.log" 2>&1; then
  echo "Resolver accepted ambiguous, different dependency refs" >&2
  exit 1
fi
grep -Fq "Ambiguous newest branches" "${test_directory}/ambiguous.log"

# Opposite orderings in two repositories resolve per repository instead of
# aborting globally: each dependency is ordered by its own repository's
# refs alone.
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/per-repo-output" \
  bash "$resolver" "$source_repository" \
    forward "$middle_dependency" \
    reverse "$reverse_dependency" \
  >"${test_directory}/per-repo.log" 2>&1
grep -Fqx "forward_branch=java-deprecation" "${test_directory}/per-repo-output"
grep -Fqx "forward_ref=${java_deprecation_tip}" "${test_directory}/per-repo-output"
# In the reverse repository the vitest ref contains the java-deprecation
# tip, so vitest is the newer branch there and resolves to its own ref.
grep -Fqx "reverse_branch=vitest" "${test_directory}/per-repo-output"
grep -Fqx "reverse_ref=${java_deprecation_tip}" "${test_directory}/per-repo-output"

# Terminal branch workflows must not create a staging/master ordering cycle.
git -C "$source_repository" switch --quiet --detach "$staging_tip"
SOURCE_BRANCH=staging GITHUB_OUTPUT="${test_directory}/staging-output" \
  bash "$resolver" "$source_repository" \
    integration "$integration_dependency" >/dev/null
grep -Fqx "integration_ref=${staging_tip}" \
  "${test_directory}/staging-output"

git -C "$source_repository" switch --quiet --detach "$master_tip"
SOURCE_BRANCH=master GITHUB_OUTPUT="${test_directory}/master-output" \
  bash "$resolver" "$source_repository" \
    root "$root_dependency" >/dev/null
grep -Fqx "root_ref=${master_tip}" "${test_directory}/master-output"

# A shared parent remains a candidate when its tip advances or is rebased,
# provided its merge-base still identifies this post-master stack.
git -C "$source_repository" switch --quiet --detach "$workflow_fix_tip"
git -C "$source_repository" update-ref \
  refs/remotes/origin/lmsousa "$advanced_lmsousa_tip"
SOURCE_BRANCH=workflow-fix EVIDENCE_REPOSITORIES="$middle_dependency" \
  GITHUB_OUTPUT="${test_directory}/advanced-output" \
  bash "$resolver" "$source_repository" \
    advanced "$advanced_dependency" >/dev/null
grep -Fqx "advanced_ref=${advanced_lmsousa_tip}" \
  "${test_directory}/advanced-output"

git -C "$source_repository" update-ref \
  refs/remotes/origin/lmsousa "$rebased_lmsousa_tip"
SOURCE_BRANCH=workflow-fix EVIDENCE_REPOSITORIES="$middle_dependency" \
  GITHUB_OUTPUT="${test_directory}/rebased-output" \
  bash "$resolver" "$source_repository" \
    rebased "$rebased_dependency" >/dev/null
grep -Fqx "rebased_ref=${rebased_lmsousa_tip}" \
  "${test_directory}/rebased-output"

# A shared sibling branch that cannot be verified as part of the event's
# stack is ignored, not fatal: the dependency resolves to the newest
# verifiable level (staging).
git -C "$source_repository" update-ref \
  refs/remotes/origin/lmsousa "$lmsousa_tip"
git -C "$source_repository" update-ref \
  refs/remotes/origin/unrelated-sibling "$unrelated_sibling_tip"
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/sibling-output" \
  bash "$resolver" "$source_repository" \
    sibling "$sibling_dependency" \
    >"${test_directory}/sibling.log" 2>&1
grep -Fqx "sibling_branch=staging" "${test_directory}/sibling-output"
grep -Fqx "sibling_ref=${staging_tip}" "${test_directory}/sibling-output"

# A shallow source checkout cannot name stack levels: fail fast instead of
# silently resolving against terminal branches.
shallow_source="${test_directory}/shallow-source"
git clone --quiet --depth 1 --config advice.detachedHead=false "file://${source_repository}" "$shallow_source"
if SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/shallow-output" \
  bash "$resolver" "$shallow_source" \
    x "$current_dependency" \
    >"${test_directory}/shallow.log" 2>&1; then
  echo "Resolver accepted a shallow source checkout" >&2
  exit 1
fi
grep -Fq "shallow" "${test_directory}/shallow.log"

# A dependency repository without the root branch contributes no evidence
# but must not abort the run; it still resolves from its own branches.
noroot_dependency="${test_directory}/noroot.git"
git clone --quiet --bare "$source_repository" "$noroot_dependency"
while IFS= read -r ref; do
  git -C "$noroot_dependency" update-ref -d "$ref"
done < <(git -C "$noroot_dependency" for-each-ref --format='%(refname)' refs/heads)
git -C "$noroot_dependency" update-ref refs/heads/staging "$staging_tip"
git -C "$noroot_dependency" update-ref refs/heads/lmsousa "$lmsousa_tip"
git -C "$noroot_dependency" update-ref refs/heads/workflow-fix "$workflow_fix_tip"
git -C "$noroot_dependency" symbolic-ref HEAD refs/heads/staging
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/noroot-output" \
  bash "$resolver" "$source_repository" \
    noroot "$noroot_dependency" \
    >"${test_directory}/noroot.log" 2>&1
grep -Fqx "noroot_branch=workflow-fix" "${test_directory}/noroot-output"
grep -Fqx "noroot_ref=${workflow_fix_tip}" "${test_directory}/noroot-output"
grep -Fqx "noroot_default=staging" "${test_directory}/noroot-output"

# Duplicate output prefixes would silently overwrite exported variables.
if SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/dup-output" \
  bash "$resolver" "$source_repository" \
    dup "$current_dependency" dup "$older_dependency" \
    >"${test_directory}/dup.log" 2>&1; then
  echo "Resolver accepted duplicate output prefixes" >&2
  exit 1
fi
grep -Fq "Duplicate output prefix" "${test_directory}/dup.log"

# === Cross-repository stacks ===
# The same branch names can stack in opposite orders in different
# repositories. Each dependency is ordered only by its own repository's
# refs and PR base metadata: other repositories' ancestry must neither
# dominate it nor elevate its branches, and the source branch's own name
# must not shadow a dependency branch.

new_fixture_repo() {
  local path="${test_directory}/$1"
  git init --quiet --initial-branch=master "$path"
  git -C "$path" config user.name "CI Resolver Test"
  git -C "$path" config user.email "ci-resolver@example.invalid"
  echo "$path"
}

fcommit() { git -C "$1" commit --quiet --allow-empty -m "$2"; }

publish_origin() {
  local repo=$1 ref branch
  while IFS= read -r ref; do
    branch=${ref#refs/heads/}
    git -C "$repo" update-ref "refs/remotes/origin/$branch" "$ref"
  done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/heads)
}

# A clava-like source stack (multi-weaver below ci-fix) with a lara-like
# dependency whose stack is switched (multi-weaver above ci-fix). The
# dependency must resolve to its own multi-weaver, never to the same-named
# source branch, and unproven descendant branches (langSpecV3 and above in
# the source's history) must not dominate or shadow the choice.
switched_source=$(new_fixture_repo switched-source)
fcommit "$switched_source" "source master"
git -C "$switched_source" switch --quiet -c staging
fcommit "$switched_source" "source staging"
git -C "$switched_source" switch --quiet -c multi-weaver
fcommit "$switched_source" "source multi-weaver"
git -C "$switched_source" switch --quiet -c ci-fix
fcommit "$switched_source" "source ci-fix"
for branch in langSpecV3 ts6 vitest dumper-v3; do
  git -C "$switched_source" switch --quiet -c "$branch"
  fcommit "$switched_source" "source $branch"
done
git -C "$switched_source" switch --quiet master
fcommit "$switched_source" "source master advanced"
git -C "$switched_source" switch --quiet staging
fcommit "$switched_source" "source staging advanced"
git -C "$switched_source" switch --quiet --detach ci-fix
publish_origin "$switched_source"

switched_dependency=$(new_fixture_repo switched-dependency)
fcommit "$switched_dependency" "dep master"
git -C "$switched_dependency" switch --quiet -c ci-fix
fcommit "$switched_dependency" "dep ci-fix"
git -C "$switched_dependency" switch --quiet -c multi-weaver
fcommit "$switched_dependency" "dep multi-weaver"
git -C "$switched_dependency" switch --quiet -c langSpecV3
fcommit "$switched_dependency" "dep langSpecV3"
git -C "$switched_dependency" switch --quiet -c staging
fcommit "$switched_dependency" "dep staging"
git -C "$switched_dependency" switch --quiet master
publish_origin "$switched_dependency"

switched_dependency_tip=$(git -C "$switched_dependency" rev-parse multi-weaver)
# An evidence repository stacking langSpecV3 below multi-weaver proves
# langSpecV3 into the pool via propagation; the dependency still resolves
# to its smallest covering branch (multi-weaver), never to that newer
# pool descendant.
switched_evidence=$(new_fixture_repo switched-evidence)
fcommit "$switched_evidence" "se master"
git -C "$switched_evidence" switch --quiet -c staging
fcommit "$switched_evidence" "se staging"
git -C "$switched_evidence" switch --quiet -c langSpecV3
fcommit "$switched_evidence" "se langSpecV3"
git -C "$switched_evidence" switch --quiet -c multi-weaver
fcommit "$switched_evidence" "se multi-weaver"
git -C "$switched_evidence" switch --quiet -c ci-fix
fcommit "$switched_evidence" "se ci-fix"
publish_origin "$switched_evidence"

SOURCE_BRANCH=ci-fix EVIDENCE_REPOSITORIES="$switched_evidence" \
  GITHUB_OUTPUT="${test_directory}/switched-output" \
  bash "$resolver" "$switched_source" \
    lara "$switched_dependency" \
    >"${test_directory}/switched.log" 2>&1
grep -Fqx "lara_branch=multi-weaver" "${test_directory}/switched-output"
grep -Fqx "lara_ref=${switched_dependency_tip}" "${test_directory}/switched-output"

# An evidence repository sharing the branch names but stacking them in the
# opposite order must not prove the dependency's branches into the stack:
# the source's own level (ci-fix) still wins for a dependency whose stack
# agrees with the source's.
polluted_source=$(new_fixture_repo polluted-source)
fcommit "$polluted_source" "l master"
git -C "$polluted_source" switch --quiet -c ci-fix
fcommit "$polluted_source" "l ci-fix 1"
fcommit "$polluted_source" "l ci-fix 2"
git -C "$polluted_source" switch --quiet --detach \
  "$(git -C "$polluted_source" rev-parse ci-fix~)"
git -C "$polluted_source" switch --quiet -c multi-weaver
fcommit "$polluted_source" "l multi-weaver"
git -C "$polluted_source" switch --quiet --detach ci-fix
publish_origin "$polluted_source"

polluted_evidence=$(new_fixture_repo polluted-evidence)
fcommit "$polluted_evidence" "e master"
git -C "$polluted_evidence" switch --quiet -c staging
fcommit "$polluted_evidence" "e staging"
git -C "$polluted_evidence" switch --quiet -c multi-weaver
fcommit "$polluted_evidence" "e multi-weaver"
git -C "$polluted_evidence" switch --quiet -c ci-fix
fcommit "$polluted_evidence" "e ci-fix 1"
fcommit "$polluted_evidence" "e ci-fix 2"
publish_origin "$polluted_evidence"

polluted_dependency=$(new_fixture_repo polluted-dependency)
fcommit "$polluted_dependency" "s master"
git -C "$polluted_dependency" switch --quiet -c staging
fcommit "$polluted_dependency" "s staging"
git -C "$polluted_dependency" switch --quiet -c ci-fix
fcommit "$polluted_dependency" "s ci-fix"
git -C "$polluted_dependency" switch --quiet -c multi-weaver
fcommit "$polluted_dependency" "s multi-weaver"
git -C "$polluted_dependency" switch --quiet master
publish_origin "$polluted_dependency"

polluted_dependency_tip=$(git -C "$polluted_dependency" rev-parse ci-fix)
SOURCE_BRANCH=ci-fix EVIDENCE_REPOSITORIES="$polluted_evidence" \
  GITHUB_OUTPUT="${test_directory}/polluted-output" \
  bash "$resolver" "$polluted_source" \
    specs "$polluted_dependency" \
    >"${test_directory}/polluted.log" 2>&1
grep -Fqx "specs_branch=ci-fix" "${test_directory}/polluted-output"
grep -Fqx "specs_ref=${polluted_dependency_tip}" "${test_directory}/polluted-output"

# PR base metadata marks a level as required even when the source's git
# history cannot prove it (rebased away). The dependency's multi-weaver
# contains ci-fix, so it is the first branch covering both levels.
pr_source=$(new_fixture_repo pr-source)
git -C "$pr_source" remote add origin "$pr_source"
fcommit "$pr_source" "p master"
git -C "$pr_source" switch --quiet -c staging
fcommit "$pr_source" "p staging"
git -C "$pr_source" switch --quiet -c multi-weaver
fcommit "$pr_source" "p multi-weaver old"
git -C "$pr_source" switch --quiet -c ci-fix
fcommit "$pr_source" "p ci-fix"
git -C "$pr_source" switch --quiet multi-weaver
git -C "$pr_source" reset --quiet --hard staging
fcommit "$pr_source" "p multi-weaver new"
git -C "$pr_source" switch --quiet --detach ci-fix
publish_origin "$pr_source"

pr_dependency=$(new_fixture_repo pr-dependency)
fcommit "$pr_dependency" "q master"
git -C "$pr_dependency" switch --quiet -c staging
fcommit "$pr_dependency" "q staging"
git -C "$pr_dependency" switch --quiet -c ci-fix
fcommit "$pr_dependency" "q ci-fix"
git -C "$pr_dependency" switch --quiet -c multi-weaver
fcommit "$pr_dependency" "q multi-weaver"
git -C "$pr_dependency" switch --quiet master
publish_origin "$pr_dependency"

pr_edges_file="${test_directory}/pr-edges"
cat > "$pr_edges_file" <<EOF
$pr_source ci-fix multi-weaver
$pr_dependency multi-weaver ci-fix
EOF

pr_dependency_tip=$(git -C "$pr_dependency" rev-parse multi-weaver)
SOURCE_BRANCH=ci-fix PR_BASE_EDGES="$pr_edges_file" \
  GITHUB_OUTPUT="${test_directory}/pr-output" \
  bash "$resolver" "$pr_source" \
    lara "$pr_dependency" \
    >"${test_directory}/pr.log" 2>&1
grep -Fqx "lara_branch=multi-weaver" "${test_directory}/pr-output"
grep -Fqx "lara_ref=${pr_dependency_tip}" "${test_directory}/pr-output"

# PR base metadata demanding a level that no dependency branch contains
# (diverged content) is an ambiguity error rather than a wrong pin.
conflict_source=$(new_fixture_repo conflict-source)
git -C "$conflict_source" remote add origin "$conflict_source"
fcommit "$conflict_source" "c master"
git -C "$conflict_source" switch --quiet -c staging
fcommit "$conflict_source" "c staging"
git -C "$conflict_source" switch --quiet -c vitest
fcommit "$conflict_source" "c vitest"
git -C "$conflict_source" switch --quiet -c java-deprecation
fcommit "$conflict_source" "c java-deprecation"
git -C "$conflict_source" switch --quiet --detach java-deprecation
publish_origin "$conflict_source"

conflict_dependency=$(new_fixture_repo conflict-dependency)
fcommit "$conflict_dependency" "d master"
git -C "$conflict_dependency" switch --quiet -c staging
fcommit "$conflict_dependency" "d staging"
git -C "$conflict_dependency" switch --quiet -c vitest
fcommit "$conflict_dependency" "d vitest"
git -C "$conflict_dependency" switch --quiet -c java-deprecation
fcommit "$conflict_dependency" "d java-deprecation"
git -C "$conflict_dependency" switch --quiet staging
git -C "$conflict_dependency" switch --quiet -c feature-x
fcommit "$conflict_dependency" "d feature-x"
git -C "$conflict_dependency" switch --quiet master
publish_origin "$conflict_dependency"

cat > "$pr_edges_file" <<EOF
$conflict_source java-deprecation feature-x
EOF

if SOURCE_BRANCH=java-deprecation PR_BASE_EDGES="$pr_edges_file" \
  GITHUB_OUTPUT="${test_directory}/conflict-output" \
  bash "$resolver" "$conflict_source" \
    specs "$conflict_dependency" \
    >"${test_directory}/conflict.log" 2>&1; then
  echo "Resolver pinned a dependency that cannot satisfy a required level" >&2
  exit 1
fi
grep -Fq "Ambiguous newest branches" "${test_directory}/conflict.log"

# The resolver can fetch PR base metadata from a GitHub API. A stub curl
# serves a canned open-pull-requests response so the fetch path is exercised
# offline.
stub_directory="${test_directory}/stub"
mkdir -p "$stub_directory"
cat > "$stub_directory/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n200' '[{"head":{"repo":{"full_name":"specs-feup/branch-resolver"},"ref":"ci-fix"},"base":{"ref":"multi-weaver"}}]'
EOF
chmod +x "$stub_directory/curl"

make_edge_fixture() {
  local prefix=$1
  local source_repository dependency
  source_repository=$(new_fixture_repo "${prefix}-source")
  git -C "$source_repository" remote add origin "$2"
  fcommit "$source_repository" "${prefix} master"
  git -C "$source_repository" switch --quiet -c staging
  fcommit "$source_repository" "${prefix} staging"
  git -C "$source_repository" switch --quiet -c multi-weaver
  fcommit "$source_repository" "${prefix} multi-weaver"
  # ci-fix branches from staging, not from multi-weaver: git history alone
  # can neither prove multi-weaver as a level below the event nor order it
  # against ci-fix, so only the PR metadata can.
  git -C "$source_repository" switch --quiet staging
  git -C "$source_repository" switch --quiet -c ci-fix
  fcommit "$source_repository" "${prefix} ci-fix"
  publish_origin "$source_repository"

  dependency=$(new_fixture_repo "${prefix}-dependency")
  fcommit "$dependency" "${prefix}d master"
  git -C "$dependency" switch --quiet -c staging
  fcommit "$dependency" "${prefix}d staging"
  git -C "$dependency" switch --quiet -c ci-fix
  fcommit "$dependency" "${prefix}d ci-fix"
  git -C "$dependency" switch --quiet -c multi-weaver
  fcommit "$dependency" "${prefix}d multi-weaver"
  git -C "$dependency" switch --quiet master
  publish_origin "$dependency"

  echo "$source_repository $dependency"
}

# A fork-originated pull_request run: the source repository's open PR lists
# the event PR, but its head repository is a fork, not the source itself.
# The head -> base edge is still the authoritative stack definition of the
# base repository's namespace and must be recorded.
read -r fork_source fork_dependency <<<"$(make_edge_fixture fork "https://github.com/specs-feup/branch-resolver.git")"
cat > "$stub_directory/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n200' '[{"head":{"repo":{"full_name":"fork-owner/branch-resolver"},"ref":"ci-fix"},"base":{"ref":"multi-weaver"}}]'
EOF
chmod +x "$stub_directory/curl"
fork_dependency_tip=$(git -C "$fork_dependency" rev-parse multi-weaver)
PATH="$stub_directory:$PATH" SOURCE_BRANCH=ci-fix \
  GITHUB_OUTPUT="${test_directory}/fork-output" \
  bash "$resolver" "$fork_source" \
    lara "$fork_dependency" \
    >"${test_directory}/fork.log" 2>&1
grep -Fqx "lara_branch=multi-weaver" "${test_directory}/fork-output"
grep -Fqx "lara_ref=${fork_dependency_tip}" "${test_directory}/fork-output"

# A GitHub Enterprise remote parses to the same owner/name repository id,
# so the API lookup is attempted for Enterprise hosts too.
read -r enterprise_source enterprise_dependency <<<"$(make_edge_fixture enterprise "https://github.example.com/specs-feup/branch-resolver.git")"
enterprise_dependency_tip=$(git -C "$enterprise_dependency" rev-parse multi-weaver)
PATH="$stub_directory:$PATH" SOURCE_BRANCH=ci-fix \
  GITHUB_OUTPUT="${test_directory}/enterprise-output" \
  bash "$resolver" "$enterprise_source" \
    lara "$enterprise_dependency" \
    >"${test_directory}/enterprise.log" 2>&1
grep -Fqx "lara_branch=multi-weaver" "${test_directory}/enterprise-output"
grep -Fqx "lara_ref=${enterprise_dependency_tip}" "${test_directory}/enterprise-output"

# Propagation is scoped to the source repository and explicitly declared
# evidence repositories: a dependency clone's own ancestry must not prove a
# branch name into other dependencies. An unrelated dependency containing a
# stray branch of a proven-elsewhere name falls back to staging.
scoped_source=$(new_fixture_repo scoped-source)
fcommit "$scoped_source" "sp master"
git -C "$scoped_source" switch --quiet -c staging
fcommit "$scoped_source" "sp staging"
git -C "$scoped_source" switch --quiet -c vitest
fcommit "$scoped_source" "sp vitest"
git -C "$scoped_source" switch --quiet -c java-deprecation
fcommit "$scoped_source" "sp java-deprecation"
git -C "$scoped_source" switch --quiet -c workflow-fix
fcommit "$scoped_source" "sp workflow-fix"
git -C "$scoped_source" switch --quiet --detach java-deprecation
git -C "$scoped_source" switch --quiet -c langspec
fcommit "$scoped_source" "sp langspec"
git -C "$scoped_source" switch --quiet --detach workflow-fix
publish_origin "$scoped_source"

scoped_prover=$(new_fixture_repo scoped-prover)
fcommit "$scoped_prover" "pr master"
git -C "$scoped_prover" switch --quiet -c staging
fcommit "$scoped_prover" "pr staging"
git -C "$scoped_prover" switch --quiet -c langspec
fcommit "$scoped_prover" "pr langspec"
git -C "$scoped_prover" switch --quiet -c java-deprecation
fcommit "$scoped_prover" "pr java-deprecation"
git -C "$scoped_prover" switch --quiet master
publish_origin "$scoped_prover"

scoped_other=$(new_fixture_repo scoped-other)
fcommit "$scoped_other" "so master"
git -C "$scoped_other" switch --quiet -c staging
fcommit "$scoped_other" "so staging"
git -C "$scoped_other" switch --quiet -c langspec
fcommit "$scoped_other" "so langspec"
git -C "$scoped_other" switch --quiet master
publish_origin "$scoped_other"

scoped_other_tip=$(git -C "$scoped_other" rev-parse staging)
SOURCE_BRANCH=workflow-fix GITHUB_OUTPUT="${test_directory}/scoped-output" \
  bash "$resolver" "$scoped_source" \
    prover "$scoped_prover" \
    other "$scoped_other" \
    >"${test_directory}/scoped.log" 2>&1
grep -Fqx "other_branch=staging" "${test_directory}/scoped-output"
grep -Fqx "other_ref=${scoped_other_tip}" "${test_directory}/scoped-output"

echo "All dependency ref resolver tests passed"
