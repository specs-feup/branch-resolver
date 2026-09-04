#!/usr/bin/env bash

set -euo pipefail

if (( $# < 3 || $# % 2 == 0 )); then
  echo "Usage: $0 SOURCE_DIRECTORY OUTPUT_PREFIX DEPENDENCY_REPOSITORY [...]" >&2
  exit 2
fi

source_directory=$1
shift

if [[ $(git -C "$source_directory" rev-parse --is-shallow-repository 2>/dev/null) != false ]]; then
  echo "Source directory '${source_directory}' is not a usable git repository (shallow clone?); check out with fetch-depth: 0" >&2
  exit 1
fi

source_branch=${SOURCE_BRANCH:?SOURCE_BRANCH must name the branch being tested}
integration_branch=${INTEGRATION_BRANCH:-staging}
root_branch=${ROOT_BRANCH:-master}

declare -a dependency_prefixes=()
declare -a dependency_repositories=()
declare -A seen_prefixes=()
while (( $# )); do
  if [[ -n ${seen_prefixes[$1]+yes} ]]; then
    echo "Duplicate output prefix '$1' in the dependency list" >&2
    exit 2
  fi
  seen_prefixes[$1]=1
  dependency_prefixes+=("$1")
  dependency_repositories+=("$2")
  shift 2
done

repository_url() {
  local repository=$1
  if [[ $repository == *://* || $repository == /* ]]; then
    echo "$repository"
  else
    echo "https://github.com/${repository}.git"
  fi
}

# The stack definition per repository: the same branch names may stack in
# opposite orders in different repositories, so every repository is
# resolved only by its own evidence.
repository_id() {
  local url=${1%.git}
  url=${url%%#*}
  if [[ $url == *://* ]]; then
    # Any https/ssh host (github.com or GitHub Enterprise): the owner/name
    # path follows the host, optionally through a port.
    url=${url#*://}
    url=${url#*/}
  elif [[ $url == *:* ]]; then
    # scp-style user@host:owner/name
    url=${url##*:}
  fi
  echo "$url"
}

# PR head -> base branches are the authoritative stack definition and take
# precedence over inferred git ancestry. Loaded from the PR_BASE_EDGES file
# (lines: "repository head base") when set, otherwise fetched from the
# GitHub API for owner/name repositories.
declare -A pr_bases=()

fetch_pr_edges() {
  local id=$1 page=1 response status json head base count
  local -a auth=()
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "Warning: curl and jq are needed to read pull request metadata for ${id}; continuing without PR evidence" >&2
    return 0
  fi
  while :; do
    if ! response=$(curl -sL --retry 3 --max-time 30 -w $'\n%{http_code}' ${auth[@]+"${auth[@]}"} \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${id}/pulls?state=open&per_page=100&page=${page}"); then
      echo "Warning: could not fetch pull request metadata for ${id}; continuing without PR evidence" >&2
      return 0
    fi
    status=${response##*$'\n'}
    json=${response%$'\n'*}
    if [[ $status == 403 || $status == 404 ]]; then
      echo "Warning: cannot read pull request metadata for ${id} (HTTP ${status}); use a token with pull-requests: read (or the classic repo scope) if this is unexpected" >&2
      return 0
    fi
    if [[ $status != 200 ]]; then
      echo "Warning: could not fetch pull request metadata for ${id} (HTTP ${status}); continuing without PR evidence" >&2
      return 0
    fi
    count=$(jq -r 'length' <<<"$json" 2>/dev/null) || {
      echo "Warning: could not parse pull request metadata for ${id}" >&2
      return 0
    }
    # Every record from this endpoint is a pull request against this
    # repository, so each head -> base branch is a stack level of this
    # repository's namespace. The head repository can be a fork of it (the
    # event pull request itself in a fork-originated run), so the head
    # repository's name must not be used as a filter.
    while IFS=$'\t' read -r head base; do
      [[ -n $head && -n $base ]] || continue
      pr_bases["${id}|${head}"]=$base
    done < <(jq -r '.[] | "\(.head.ref)\t\(.base.ref)"' \
      <<<"$json")
    [[ $count -lt 100 ]] && break
    (( page += 1 ))
  done
}

source_repository_id=
if origin_url=$(git -C "$source_directory" remote get-url origin 2>/dev/null); then
  source_repository_id=$(repository_id "$origin_url")
fi

# Only the source's own PR base chain is consulted: it names the stack
# levels at or below the event. Dependency repositories are resolved by
# their own content alone.
if [[ -n ${PR_BASE_EDGES:-} ]]; then
  while read -r repository head base; do
    [[ -n $repository && -n $head && -n $base ]] || continue
    pr_bases["${repository}|${head}"]=$base
  done < "$PR_BASE_EDGES"
elif [[ $source_repository_id =~ ^[^/]+/[^/]+$ ]]; then
  fetch_pr_edges "$source_repository_id"
fi

evidence_directory=$(mktemp -d)
declare -a evidence_paths=("$source_directory")
declare -a evidence_ref_prefixes=("refs/remotes/origin/")
declare -A cloned_paths=()
declare -A repo_index_by_name=()

clone_evidence_repository() {
  local repository=$1

  if [[ -n ${cloned_paths[$repository]+yes} ]]; then
    return
  fi

  local clone_path="${evidence_directory}/repository-${#cloned_paths[@]}.git"
  git clone --quiet --bare --filter=blob:none \
    "$(repository_url "$repository")" "$clone_path"
  cloned_paths[$repository]=$clone_path
  repo_index_by_name[$repository]=$(( ${#evidence_paths[@]} ))
  evidence_paths+=("$clone_path")
  evidence_ref_prefixes+=("refs/heads/")
}

for repository in "${dependency_repositories[@]}"; do
  clone_evidence_repository "$repository"
done

declare -A propagation_repos=()
propagation_repos[0]=1

if [[ -n ${EVIDENCE_REPOSITORIES:-} ]]; then
  read -r -a additional_evidence <<< "$EVIDENCE_REPOSITORIES"
  for repository in "${additional_evidence[@]}"; do
    clone_evidence_repository "$repository"
    index=${repo_index_by_name[$repository]:-}
    [[ -n $index ]] && propagation_repos[$index]=1
  done
fi

# A moved branch is relevant only when its name is shared by repositories.
# Count each repository once so private one-off branches do not pollute the
# global candidate set.
declare -A branch_presence=()
for ((repository_index = 0; repository_index < ${#evidence_paths[@]}; repository_index++)); do
  repository_path=${evidence_paths[$repository_index]}
  ref_prefix=${evidence_ref_prefixes[$repository_index]}
  while IFS= read -r ref; do
    branch=${ref#"$ref_prefix"}
    [[ $branch == HEAD ]] && continue
    branch_presence[$branch]=$(( ${branch_presence[$branch]:-0} + 1 ))
  done < <(
    git -C "$repository_path" for-each-ref \
      --format='%(refname)' "${ref_prefix%/}"
  )
done

declare -a candidates=()
declare -A seen_candidates=()
declare -A candidate_proven=()

add_candidate() {
  local branch=$1
  local proven=${2:-true}
  if [[ -n $branch && -z ${seen_candidates[$branch]+yes} ]]; then
    seen_candidates[$branch]=${#candidates[@]}
    candidate_proven[${#candidates[@]}]=$proven
    candidates+=("$branch")
  elif [[ -n $branch && $proven == true ]]; then
    candidate_proven[${seen_candidates[$branch]}]=true
  fi
}

add_candidate "$source_branch"

collect_candidates() {
  local repository_path=$1
  local ref_prefix=$2
  local start_ref=$3
  local required=$4
  local mark_proven=$5
  local root_ref="${ref_prefix}${root_branch}"

  if ! git -C "$repository_path" rev-parse --verify "${start_ref}^{commit}" >/dev/null 2>&1; then
    if [[ $required == true ]]; then
      echo "Cannot resolve the workflow commit in ${repository_path}" >&2
      exit 1
    fi
    return
  fi
  if ! git -C "$repository_path" rev-parse --verify "${root_ref}^{commit}" >/dev/null 2>&1; then
    if [[ $required == true ]]; then
      echo "Cannot find root branch '${root_branch}' in ${repository_path}" >&2
      exit 1
    fi
    return
  fi

  declare -A distance_by_commit=()
  local distance=0
  local reached_root=false
  local commit
  while IFS= read -r commit; do
    distance_by_commit[$commit]=$distance
    ((distance += 1))
    if git -C "$repository_path" merge-base --is-ancestor "$commit" "$root_ref"; then
      reached_root=true
      break
    fi
  done < <(git -C "$repository_path" rev-list --first-parent "$start_ref")

  if [[ $reached_root != true ]]; then
    if [[ $required == true ]]; then
      echo "The workflow commit's first-parent history does not reach '${root_branch}'" >&2
      exit 1
    fi
    return
  fi
  local root_distance=$((distance - 1))

  local ordered_refs="${evidence_directory}/candidate-refs-${#candidates[@]}-${distance}"
  : > "$ordered_refs"
  local ref object branch
  while IFS=$'\t' read -r ref object; do
    branch=${ref#"$ref_prefix"}
    [[ $branch == HEAD ]] && continue
    [[ $branch == "$source_branch" ]] && continue
    [[ $branch == "$integration_branch" ]] && continue
    [[ $branch == "$root_branch" ]] && continue

    if [[ -n ${distance_by_commit[$object]+yes} ]]; then
      printf '%s\t%s\t%s\n' "${distance_by_commit[$object]}" "$branch" "$mark_proven" >> "$ordered_refs"
      continue
    fi

    # The branch may have advanced after a child was created. Its merge-base
    # still identifies the old tip on the event's stack. Requiring the name in
    # multiple repositories and a fork point newer than the root boundary
    # avoids treating every branch from master as part of this stack.
    [[ ${branch_presence[$branch]:-0} -ge 2 ]] || continue
    merge_base=$(git -C "$repository_path" merge-base "$start_ref" "$ref" 2>/dev/null || true)
    [[ -n $merge_base && -n ${distance_by_commit[$merge_base]+yes} ]] || continue
    [[ ${distance_by_commit[$merge_base]} -lt $root_distance ]] || continue
    printf '%s\t%s\tfalse\n' "${distance_by_commit[$merge_base]}" "$branch" >> "$ordered_refs"
  done < <(
    git -C "$repository_path" for-each-ref \
      --format='%(refname)%09%(objectname)' "${ref_prefix%/}"
  )

  while IFS=$'\t' read -r _ branch proven; do
    add_candidate "$branch" "$proven"
  done < <(sort -k1,1n -k2,2 -u "$ordered_refs")
}

# HEAD is the immutable event commit. Never substitute the mutable remote tip.
# Only the source repository's own history may mark a branch as proven: the
# same branch names in other repositories can legitimately stack in a
# different order.
collect_candidates "$source_directory" "refs/remotes/origin/" HEAD true true

for ((repository_index = 1; repository_index < ${#evidence_paths[@]}; repository_index++)); do
  repository_path=${evidence_paths[$repository_index]}
  source_ref="refs/heads/${source_branch}"
  if git -C "$repository_path" show-ref --verify --quiet "$source_ref"; then
    collect_candidates "$repository_path" "refs/heads/" "$source_ref" false false
  fi
done

if [[ $source_branch != "$root_branch" ]]; then
  add_candidate "$integration_branch"
fi
add_candidate "$root_branch"

# The source's own PR base chain names the stack levels at or below the
# event, even when its git history can no longer prove them (a rebase
# without a merge commit). They are required and selectable for
# dependencies.
# Stack levels at or below the event commit that a dependency branch must
# contain, plus the event's own branch: the first dependency branch
# covering all of them is the match.
declare -A required_levels=()
required_levels[$source_branch]=1
base_branch=$source_branch
declare -A visited_bases=()
while [[ -n ${pr_bases["${source_repository_id}|${base_branch}"]+yes} ]]; do
  base_branch=${pr_bases["${source_repository_id}|${base_branch}"]}
  [[ $base_branch == "$integration_branch" || $base_branch == "$root_branch" ]] && break
  [[ -n ${visited_bases[$base_branch]+yes} ]] && break
  visited_bases[$base_branch]=1
  required_levels[$base_branch]=1
  add_candidate "$base_branch" true
done

candidate_count=${#candidates[@]}

# A shared branch whose source-repository tip is contained in the event
# commit is a stack level at or below the event: required for dependencies
# and selectable even when it only entered the event through a merge.
for ((i = 0; i < candidate_count; i++)); do
  branch=${candidates[$i]}
  [[ $branch == "$source_branch" || $branch == "$integration_branch" || $branch == "$root_branch" ]] && continue
  if git -C "$source_directory" rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}" >/dev/null 2>&1 &&
    git -C "$source_directory" merge-base --is-ancestor "refs/remotes/origin/${branch}" HEAD; then
    required_levels[$branch]=1
    candidate_proven[$i]=true
  fi
done

is_first_parent_ancestor() {
  local repository_path=$1
  local older=$2
  local newer=$3
  local commit

  while IFS= read -r commit; do
    [[ $commit == "$older" ]] && return 0
  done < <(git -C "$repository_path" rev-list --first-parent "$newer")
  return 1
}

# Each repository contributes strict first-parent evidence scoped to itself.
# Equal refs are neutral; missing or diverged refs contribute no ordering.
# The source branch's own ref is only compared inside the source repository:
# elsewhere the same name is an independent branch that may legitimately sit
# anywhere in that repository's stack.
declare -A strict_edges=()

for ((repository_index = 0; repository_index < ${#evidence_paths[@]}; repository_index++)); do
  repository_path=${evidence_paths[$repository_index]}
  ref_prefix=${evidence_ref_prefixes[$repository_index]}

  for ((i = 0; i < candidate_count; i++)); do
    left_branch=${candidates[$i]}
    [[ $left_branch == "$integration_branch" || $left_branch == "$root_branch" ]] && continue
    if [[ $repository_index -eq 0 && $left_branch == "$source_branch" ]]; then
      continue
    fi
    left_ref="${ref_prefix}${left_branch}"
    left_sha=$(git -C "$repository_path" rev-parse --verify "${left_ref}^{commit}" 2>/dev/null || true)
    [[ -n $left_sha ]] || continue

    for ((j = i + 1; j < candidate_count; j++)); do
      right_branch=${candidates[$j]}
      [[ $right_branch == "$integration_branch" || $right_branch == "$root_branch" ]] && continue
      if [[ $repository_index -eq 0 && $right_branch == "$source_branch" ]]; then
        continue
      fi
      right_ref="${ref_prefix}${right_branch}"
      right_sha=$(git -C "$repository_path" rev-parse --verify "${right_ref}^{commit}" 2>/dev/null || true)
      [[ -n $right_sha && $left_sha != "$right_sha" ]] || continue

      if is_first_parent_ancestor "$repository_path" "$right_sha" "$left_sha"; then
        strict_edges["${repository_index},${i},${j}"]=1
      elif is_first_parent_ancestor "$repository_path" "$left_sha" "$right_sha"; then
        strict_edges["${repository_index},${j},${i}"]=1
      fi
    done
  done
done

# Strict evidence validates an uncertain candidate only when it connects to a
# branch already observed directly on the source's stack. Propagate that
# proof through a chain of strict first-parent relationships. The source
# branch's own node is proven by definition and must not vouch for other
# names through another repository's ordering, and proof only propagates
# from the source repository and explicitly declared evidence repositories:
# a dependency clone's own ancestry must not elevate a branch name in other
# dependencies, where the same name can be an unrelated branch.
proof_changed=true
while [[ $proof_changed == true ]]; do
  proof_changed=false
  for edge in "${!strict_edges[@]}"; do
    repo_index=${edge%%,*}
    [[ -n ${propagation_repos[$repo_index]+yes} ]] || continue
    rest=${edge#*,}
    newer_index=${rest%,*}
    older_index=${rest#*,}
    [[ ${candidates[$newer_index]} == "$source_branch" ]] && continue
    if [[ ${candidate_proven[$newer_index]:-false} == true &&
      ${candidate_proven[$older_index]:-false} != true ]]; then
      candidate_proven[$older_index]=true
      proof_changed=true
    fi
  done
done

printf -v candidate_chain '%s -> ' "${candidates[@]}"
candidate_chain=${candidate_chain% -> }
echo "Dependency branch candidates: ${candidate_chain}"

for ((dependency_index = 0; dependency_index < ${#dependency_repositories[@]}; dependency_index++)); do
  prefix=${dependency_prefixes[$dependency_index]}
  repository=${dependency_repositories[$dependency_index]}
  repository_path=${cloned_paths[$repository]}

  default_branch=$(git -C "$repository_path" symbolic-ref --short HEAD)
  default_branch=${default_branch#refs/heads/}

  # Only branches proven to sit at or below the event's stack level are
  # selectable. A shared branch that cannot be verified is ignored rather
  # than guessed about.
  declare -a non_terminal_pool=()
  declare -a ignored_branches=()
  declare -A pool_sha=()
  staging_sha=""
  master_sha=""
  for ((i = 0; i < candidate_count; i++)); do
    branch=${candidates[$i]}
    sha=$(git -C "$repository_path" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)
    [[ -n $sha ]] || continue
    if [[ ${candidate_proven[$i]:-false} != true ]]; then
      ignored_branches+=("$branch")
      continue
    fi
    if [[ $branch == "$integration_branch" ]]; then
      staging_sha=$sha
    elif [[ $branch == "$root_branch" ]]; then
      master_sha=$sha
    else
      non_terminal_pool+=("$i")
      pool_sha[$i]=$sha
    fi
  done
  if (( ${#ignored_branches[@]} > 0 )); then
    echo "Ignoring shared branches that cannot be placed in ${repository}: ${ignored_branches[*]}" >&2
  fi

  if (( ${#non_terminal_pool[@]} == 0 )); then
    # No stack level of the event exists here: fall back to the
    # conventional terminal levels.
    echo "No proven stack level of the event exists in ${repository}; using terminal branches" >&2
    if [[ -n $staging_sha ]]; then
      selected_branch=$integration_branch
      selected_sha=$staging_sha
    elif [[ -n $master_sha ]]; then
      selected_branch=$root_branch
      selected_sha=$master_sha
    else
      echo "None of the candidate branches exists in ${repository}" >&2
      exit 1
    fi
  else
    # The matching branch is the first (smallest) pool branch that contains
    # every required stack level present in this repository.
    declare -a qualifying=()
    for i in "${non_terminal_pool[@]}"; do
      branch=${candidates[$i]}
      ok=true
      for level in "${!required_levels[@]}"; do
        [[ $level == "$branch" ]] && continue
        if ! git -C "$repository_path" rev-parse --verify --quiet "refs/heads/${level}^{commit}" >/dev/null 2>&1; then
          continue
        fi
        if ! git -C "$repository_path" merge-base --is-ancestor "refs/heads/${level}" "refs/heads/${branch}"; then
          ok=false
          break
        fi
      done
      [[ $ok == true ]] && qualifying+=("$i")
    done
    if (( ${#qualifying[@]} == 0 )); then
      names=""
      for i in "${non_terminal_pool[@]}"; do
        names+="${candidates[$i]}, "
      done
      names=${names%, }
      echo "Ambiguous newest branches in ${repository}: ${names}; no branch covers the required levels: ${!required_levels[*]}" >&2
      exit 1
    fi
    # Keep only the smallest qualifying branches: a branch containing
    # another qualifying branch is newer than needed, since that other
    # branch already covers the required levels.
    declare -a minimal=()
    for i in "${qualifying[@]}"; do
      is_minimal=true
      for j in "${qualifying[@]}"; do
        [[ $i == "$j" ]] && continue
        [[ ${pool_sha[$i]} == "${pool_sha[$j]}" ]] && continue
        if git -C "$repository_path" merge-base --is-ancestor "refs/heads/${candidates[$j]}" "refs/heads/${candidates[$i]}"; then
          is_minimal=false
          break
        fi
      done
      [[ $is_minimal == true ]] && minimal+=("$i")
    done
    selected_index=${minimal[0]}
    selected_sha=${pool_sha[$selected_index]}
    if (( ${#minimal[@]} > 1 )); then
      for i in "${minimal[@]}"; do
        if [[ ${pool_sha[$i]} != "$selected_sha" ]]; then
          names=""
          for j in "${minimal[@]}"; do
            names+="${candidates[$j]}, "
          done
          names=${names%, }
          echo "Ambiguous newest branches in ${repository}: ${names}; required levels: ${!required_levels[*]}" >&2
          exit 1
        fi
      done
    fi
    selected_branch=${candidates[$selected_index]}
  fi

  echo "Using '${selected_branch}' (${selected_sha}) for ${repository}"
  {
    echo "${prefix}_ref=${selected_sha}"
    echo "${prefix}_branch=${selected_branch}"
    echo "${prefix}_default=${default_branch}"
  } >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
done
