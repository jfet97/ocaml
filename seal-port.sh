#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# seal-port.sh
#
# Ports the [%seal] patch to multiple OCaml release tags.
#
# ---- Quick start -------------------------------------------------
#
#   # First time setup (only once):
#   git remote add upstream https://github.com/ocaml/ocaml.git
#
#   # Commit your [%seal] changes on a dedicated branch:
#   ./seal-port.sh setup
#
#   # Port to specific releases:
#   ./seal-port.sh port 5.4.1 5.5.0-alpha3
#
#   # Sync your trunk with upstream (get latest commits):
#   ./seal-port.sh sync
#
#   # When a new upstream release comes out:
#   ./seal-port.sh fetch
#   ./seal-port.sh port 5.5.0-beta1
#
#   # See status of all sealed versions:
#   ./seal-port.sh status
#
#   # Push everything to your GitHub fork:
#   ./seal-port.sh push
#
# ---- How this works ----------------------------------------------
#
# You have a FORK of the OCaml compiler. That means:
#
#   - "upstream" = the official OCaml repo (github.com/ocaml/ocaml)
#     You don't control this. The OCaml team pushes here.
#
#   - "origin" = YOUR fork on GitHub
#     You control this. This is where your [%seal] code lives.
#
# The goal is to keep your [%seal] patch isolated on its own branch
# ("seal"), separate from upstream's trunk. This way:
#
#   upstream/trunk:  A---B---C---D---E---F   (OCaml team pushes here)
#                                         \
#   seal branch:                           F---[%seal]  (your patch)
#
# Your trunk stays clean (mirrors upstream exactly). Your patch
# lives on the "seal" branch. When upstream updates, you sync trunk
# and rebase your patch on top.
#
# ---- Git concepts ------------------------------------------------
#
# TAG: a named label pointing to a specific commit, forever.
#   "5.4.1" always means the exact code that was released as
#   OCaml 5.4.1. Tags never move. Think of them as bookmarks.
#
# BRANCH: a movable pointer. The "5.5" branch keeps getting new
#   commits. At some point a commit gets tagged "5.5.0-alpha3",
#   and that tag is frozen, even as the branch moves on.
#
# CHERRY-PICK: copy-pastes a commit onto a different branch.
#   If the surrounding code differs, git reports a CONFLICT:
#   you edit the file, pick which version to keep, then continue.
#   This is how we apply [%seal] to older OCaml versions.
#
# REBASE: moves your commits on top of new upstream commits.
#   Like picking up your sticky note and re-attaching it to the
#   latest page. Used by "sync" to keep [%seal] on top of trunk.
#
# The script creates "<tag>-sealed" tags (e.g. "5.4.1-sealed")
# for each version where [%seal] was successfully applied.
# Re-running is safe: existing tags/branches are recreated.
# ------------------------------------------------------------------

SEAL_COMMIT=""
SEAL_BRANCH="seal"
BUILD_TIMEOUT=600

# macOS doesn't have `timeout` — use gtimeout (brew install coreutils) or skip
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[seal-port]${NC} $*"; }
warn()  { echo -e "${YELLOW}[seal-port]${NC} $*"; }
error() { echo -e "${RED}[seal-port]${NC} $*"; }
info()  { echo -e "${BLUE}[seal-port]${NC} $*"; }

# ensure we're in the repo root
ensure_repo_root() {
  if [ ! -f "VERSION" ] || [ ! -d "typing" ]; then
    error "Run this script from the OCaml repo root."
    exit 1
  fi
}

# check that the "upstream" remote exists
ensure_upstream() {
  if ! git remote get-url upstream >/dev/null 2>&1; then
    error "Remote 'upstream' not configured."
    error ""
    error "Run this once:"
    error "  git remote add upstream https://github.com/ocaml/ocaml.git"
    exit 1
  fi
}

# find the seal commit (the compiler patch, not the script commit)
# looks for "Add [%seal] extension" — the specific compiler patch message
find_seal_commit() {
  SEAL_COMMIT=$(git log --all --grep='Add \[%seal\] extension' --format='%H' | head -1)
  if [ -z "$SEAL_COMMIT" ]; then
    # fallback: any commit mentioning [%seal] that touches typecore.ml
    SEAL_COMMIT=$(git log --all --grep='\[%seal\]' --format='%H' -- typing/typecore.ml | head -1)
  fi
  if [ -z "$SEAL_COMMIT" ]; then
    error "No seal compiler patch commit found."
    error ""
    error "Run './seal-port.sh setup' first to create the seal commit."
    exit 1
  fi
  log "Found seal commit: $(git log --oneline -1 "$SEAL_COMMIT")"
}

# ensure seal-port.sh is committed on the seal branch
ensure_script_committed() {
  if ! git rev-parse --verify "$SEAL_BRANCH" >/dev/null 2>&1; then
    return 0
  fi
  # check if seal-port.sh is already tracked on the seal branch
  if git ls-tree "$SEAL_BRANCH" --name-only | grep -q '^seal-port.sh$'; then
    return 0
  fi
  # script exists on disk but not in the branch — commit it
  if [ -f "seal-port.sh" ]; then
    local current_branch
    current_branch=$(git branch --show-current)
    git checkout "$SEAL_BRANCH"
    git add seal-port.sh
    git commit -m "Add seal-port.sh for porting [%seal] across OCaml versions"
    log "Committed porting script on seal branch."
    git checkout "$current_branch" 2>/dev/null || true
  fi
}

# ---- Commands ----------------------------------------------------

# setup: commit changes on a dedicated "seal" branch
cmd_setup() {
  log "Setting up the seal branch..."

  # check for uncommitted seal changes
  local has_changes=false
  if git diff --name-only | grep -q 'typing/typecore.ml'; then
    has_changes=true
  fi
  if [ -n "$(git ls-files --others --exclude-standard testsuite/tests/typing-seal/ 2>/dev/null)" ]; then
    has_changes=true
  fi

  # check if seal branch already exists with the commit
  if git rev-parse --verify "$SEAL_BRANCH" >/dev/null 2>&1; then
    if git log "$SEAL_BRANCH" --grep='\[%seal\]' --format='%H' | head -1 | grep -q .; then
      log "Seal branch already exists with [%seal] commit."
      log "  branch: $SEAL_BRANCH"
      log "  commit: $(git log "$SEAL_BRANCH" --grep='\[%seal\]' --oneline | head -1)"
      if [ "$has_changes" = true ]; then
        warn "You have uncommitted changes. To update, amend manually:"
        warn "  git checkout seal"
        warn "  git add typing/typecore.ml testsuite/tests/typing-seal/"
        warn "  git commit --amend"
      fi
      # ensure the script itself is also committed
      ensure_script_committed
      return 0
    fi
  fi

  if [ "$has_changes" = false ]; then
    # maybe already committed on current branch?
    if git log --grep='\[%seal\]' --format='%H' | head -1 | grep -q .; then
      log "Seal commit already exists on current branch."
      return 0
    fi
    error "No uncommitted seal changes found and no seal commit exists."
    error "Make your changes to typing/typecore.ml first, then run this."
    return 1
  fi

  local current_branch
  current_branch=$(git branch --show-current)

  # create seal branch from current position
  if ! git rev-parse --verify "$SEAL_BRANCH" >/dev/null 2>&1; then
    git checkout -b "$SEAL_BRANCH"
    log "Created branch '$SEAL_BRANCH' from '$current_branch'"
  else
    git checkout "$SEAL_BRANCH"
  fi

  git add typing/typecore.ml
  git add testsuite/tests/typing-seal/ 2>/dev/null || true
  git commit -m "Add [%seal] extension to close open object rows"

  log "Committed compiler patch on branch '$SEAL_BRANCH':"
  log "  $(git log --oneline -1)"

  # second commit: the script itself (separate so cherry-pick only
  # grabs the compiler patch, not this tooling script)
  if [ -f "seal-port.sh" ]; then
    git add seal-port.sh
    git commit -m "Add seal-port.sh for porting [%seal] across OCaml versions"
    log "Committed porting script:"
    log "  $(git log --oneline -1)"
  fi

  echo ""
  log "You can now port to release tags:"
  log "  ./seal-port.sh port 5.4.1 5.5.0-alpha3"
}

# fetch: get latest tags and branches from upstream
cmd_fetch() {
  ensure_upstream
  log "Fetching from upstream..."
  git fetch upstream --tags
  log "Done. Available 5.x tags:"
  git tag -l '5.*' | sort -V | sed 's/^/  /'
}

# sync: update trunk from upstream and rebase seal on top
cmd_sync() {
  ensure_upstream
  find_seal_commit

  local current_branch
  current_branch=$(git branch --show-current)

  # stash uncommitted changes
  local did_stash=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "Stashing uncommitted changes..."
    git stash push -m "seal-port: auto-stash before sync" --quiet
    did_stash=true
  fi

  # update trunk
  log "Updating trunk from upstream..."
  git checkout trunk
  git pull upstream trunk

  # rebase seal branch on top
  if git rev-parse --verify "$SEAL_BRANCH" >/dev/null 2>&1; then
    log "Rebasing seal branch on top of trunk..."
    git checkout "$SEAL_BRANCH"
    if git rebase trunk; then
      log "Seal branch rebased successfully."
    else
      error "Rebase had conflicts. Fix them, then:"
      error "  git add <resolved files>"
      error "  git rebase --continue"
      git checkout "$current_branch" 2>/dev/null || true
      if [ "$did_stash" = true ]; then git stash pop --quiet; fi
      return 1
    fi
  fi

  git checkout "$current_branch" 2>/dev/null || git checkout trunk
  if [ "$did_stash" = true ]; then
    log "Restoring stashed changes..."
    git stash pop --quiet
  fi
  log "Sync complete."
}

# status: show all sealed tags and branches
cmd_status() {
  echo ""
  info "=== Seal branches ==="
  local branches
  branches=$(git branch --list 'seal*' 2>/dev/null)
  if [ -n "$branches" ]; then
    echo "$branches" | while read -r b; do
      echo "  $b"
    done
  else
    echo "  (none)"
  fi

  echo ""
  info "=== Sealed tags ==="
  local tags
  tags=$(git tag -l '*-sealed' 2>/dev/null | sort -V)
  if [ -n "$tags" ]; then
    echo "$tags" | while read -r t; do
      echo "  $t  ->  $(git log --oneline -1 "$t")"
    done
  else
    echo "  (none)"
  fi

  echo ""
  info "=== Available upstream 5.x tags (not yet sealed) ==="
  local available=""
  for t in $(git tag -l '5.*' | sort -V); do
    if ! git tag -l "${t}-sealed" | grep -q .; then
      available+="  $t"$'\n'
    fi
  done
  if [ -n "$available" ]; then
    echo "$available"
  else
    echo "  (all tagged)"
  fi
}

# push: push all seal branches and tags to origin
cmd_push() {
  log "Pushing seal branches and tags to origin..."

  # push seal branch
  if git rev-parse --verify "$SEAL_BRANCH" >/dev/null 2>&1; then
    git push origin "$SEAL_BRANCH" --force-with-lease
    log "Pushed branch: $SEAL_BRANCH"
  fi

  # push all seal-* branches
  for branch in $(git branch --list 'seal-*' --format='%(refname:short)'); do
    git push origin "$branch" --force-with-lease
    log "Pushed branch: $branch"
  done

  # push all -sealed tags
  local sealed_tags
  sealed_tags=$(git tag -l '*-sealed')
  if [ -n "$sealed_tags" ]; then
    echo "$sealed_tags" | xargs git push origin
    log "Pushed sealed tags"
  fi

  # for each seal-<tag> branch, push a base-<tag> branch pointing to
  # the original tag. This lets you create clean PRs on GitHub:
  #   seal-5.4.1 -> base-5.4.1  (shows only the seal diff)
  for branch in $(git branch --list 'seal-*' --format='%(refname:short)'); do
    local tag="${branch#seal-}"  # "seal-5.4.1" -> "5.4.1"
    if git rev-parse "$tag" >/dev/null 2>&1; then
      git push origin "$tag:refs/heads/base-${tag}" --force
      log "Pushed base branch: base-${tag} (from tag $tag)"
    fi
  done

  log "Done."
  echo ""
  log "To create clean PRs on GitHub, use these base branches:"
  for branch in $(git branch --list 'seal-*' --format='%(refname:short)'); do
    local tag="${branch#seal-}"
    log "  $branch -> base-${tag}"
  done
}

# port: cherry-pick seal onto one or more tags
cmd_port() {
  if [ $# -eq 0 ]; then
    error "Usage: $0 port <tag1> [tag2] ..."
    error ""
    error "Example:"
    error "  $0 port 5.4.1 5.5.0-alpha3"
    error ""
    error "Available tags:"
    git tag -l '5.*' | sort -V | sed 's/^/  /'
    exit 1
  fi

  find_seal_commit

  local tags=("$@")
  local succeeded=()
  local failed=()

  local original_branch
  original_branch=$(git branch --show-current)

  # stash any uncommitted changes (including to this script itself)
  # so that git checkout doesn't fail when switching branches
  local did_stash=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    log "Stashing uncommitted changes..."
    git stash push -m "seal-port: auto-stash before porting" --quiet
    did_stash=true
  fi

  for tag in "${tags[@]}"; do
    if port_to_tag "$tag"; then
      succeeded+=("$tag")
    else
      failed+=("$tag")
    fi
  done

  git checkout "$original_branch" 2>/dev/null || true

  # restore stashed changes
  if [ "$did_stash" = true ]; then
    log "Restoring stashed changes..."
    git stash pop --quiet
  fi

  # summary
  echo ""
  log "========== Summary =========="
  if [ ${#succeeded[@]} -gt 0 ]; then
    log "Succeeded:"
    for tag in "${succeeded[@]}"; do
      log "  $tag  ->  branch: seal-${tag}  tag: ${tag}-sealed"
    done
  fi
  if [ ${#failed[@]} -gt 0 ]; then
    error "Failed:"
    for tag in "${failed[@]}"; do
      error "  $tag"
    done
  fi
  echo ""
  log "Run './seal-port.sh push' to push everything to your fork."
}

# check that a tag exists
check_tag() {
  local tag="$1"
  if ! git rev-parse "$tag" >/dev/null 2>&1; then
    error "Tag '$tag' does not exist."
    error "Run './seal-port.sh fetch' to get the latest tags, then try again."
    error ""
    error "Available 5.x tags:"
    git tag -l '5.*' | sort -V | sed 's/^/  /'
    return 1
  fi
}

# ---- Version-specific fixups --------------------------------------
#
# When cherry-picking the seal commit onto older versions, two things
# can go wrong:
#
#   1. CONFLICT: the surrounding code in typecore.ml differs between
#      trunk and the target version (e.g. functions were added/removed
#      near the insertion point). Git can't merge automatically.
#
#   2. API DIFFERENCES: the seal code itself uses types/functions that
#      changed name between versions (e.g. pack_constraints vs
#      pack_cstrs, presence/absence of Tfunctor).
#
# This section handles both automatically for known versions.
# ------------------------------------------------------------------

# extract the OCaml major.minor version from a tag like "5.4.1" -> "5.4"
tag_major_minor() {
  echo "$1" | grep -oE '^[0-9]+\.[0-9]+'
}

# resolve cherry-pick conflicts in typecore.ml
# the conflict is always the same pattern: trunk has extra functions
# (do_relaxed_value_restriction, check_let_univars) before
# seal_object_rows that don't exist in older versions.
# we keep only the seal_object_rows function.
auto_resolve_conflict() {
  local file="typing/typecore.ml"

  if ! grep -q '<<<<<<<' "$file" 2>/dev/null; then
    return 1  # no conflict markers, can't auto-resolve
  fi

  # check it's the known conflict pattern: conflict is in typecore.ml
  # and contains seal_object_rows
  if ! grep -q 'seal_object_rows' "$file" 2>/dev/null; then
    return 1  # unknown conflict, bail
  fi

  log "Auto-resolving known conflict in typecore.ml..."

  # the conflict always looks like:
  #   <<<<<<< HEAD
  #   =======
  #   <trunk-only functions...>
  #   <seal_object_rows function>
  #   >>>>>>> ...
  #
  # resolution: drop everything between <<<< and ====,
  # keep seal_object_rows (and only that) between ==== and >>>>,
  # remove all conflict markers.

  # use a python one-liner because sed can't handle multiline well
  python3 -c "
import re, sys

content = open('$file').read()

def resolve(m):
    theirs = m.group(2)
    # keep only seal_object_rows and onwards, drop other functions
    seal_start = theirs.find('(* [%seal expr]')
    if seal_start == -1:
        # fallback: keep everything from theirs
        return theirs
    return theirs[seal_start:]

content = re.sub(
    r'<<<<<<<[^\n]*\n(.*?)=======\n(.*?)>>>>>>>[^\n]*\n',
    resolve,
    content,
    flags=re.DOTALL
)

open('$file', 'w').write(content)
"

  if grep -q '<<<<<<<' "$file" 2>/dev/null; then
    error "Auto-resolution left conflict markers — manual fix needed"
    return 1
  fi

  log "Conflict resolved automatically"
  return 0
}

# apply version-specific API fixups to seal_object_rows
apply_version_fixups() {
  local tag="$1"
  local version
  version=$(tag_major_minor "$tag")
  local file="typing/typecore.ml"

  local applied_any=false

  # 5.4 and earlier: pack_cstrs instead of pack_constraints
  if grep -q 'pack_constraints' "$file" 2>/dev/null; then
    local has_field
    has_field=$(git show "$tag":typing/types.mli 2>/dev/null \
                | grep -c 'pack_cstrs' || true)
    if [ "$has_field" -gt 0 ]; then
      log "Fixup: pack_constraints -> pack_cstrs (5.4 API)"
      sed -i '' 's/pack_constraints/pack_cstrs/g' "$file"
      applied_any=true
    fi
  fi

  # 5.4 and earlier: no Tfunctor in type_desc
  local has_tfunctor
  has_tfunctor=$(git show "$tag":typing/types.mli 2>/dev/null \
                 | grep -c 'Tfunctor' || true)
  if [ "$has_tfunctor" -eq 0 ]; then
    if grep -q 'Tfunctor' "$file" 2>/dev/null; then
      log "Fixup: removing Tfunctor (not in $version)"
      # remove "| Tfunctor _ " from the catch-all pattern
      sed -i '' 's/| Tfield _ | Tfunctor _/| Tfield _/' "$file"
      applied_any=true
    fi
  fi

  # 5.0-5.1: Ttuple was type_expr list, not (string option * type_expr) list
  local tuple_labeled
  tuple_labeled=$(git show "$tag":typing/types.mli 2>/dev/null \
                  | grep 'Ttuple' | grep -c 'string option' || true)
  if [ "$tuple_labeled" -eq 0 ]; then
    if grep -q 'fun (_, ty) -> walk ty' "$file" 2>/dev/null; then
      log "Fixup: Ttuple uses plain list (no labels in $version)"
      sed -i '' 's/List.iter (fun (_, ty) -> walk ty) tys/List.iter walk tys/' "$file"
      applied_any=true
    fi
  fi

  if [ "$applied_any" = true ]; then
    log "Version-specific fixups applied for $version"
  fi
}

port_to_tag() {
  local tag="$1"
  local branch="seal-${tag}"
  local sealed_tag="${tag}-sealed"

  log "--- Porting to $tag ---"

  if ! check_tag "$tag"; then
    return 1
  fi

  # clean up previous run
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    warn "Branch '$branch' already exists, recreating it"
    git branch -D "$branch"
  fi
  if git rev-parse --verify "$sealed_tag" >/dev/null 2>&1; then
    warn "Tag '$sealed_tag' already exists, recreating it"
    git tag -d "$sealed_tag"
  fi

  # create branch from tag
  log "Creating branch '$branch' from tag '$tag'"
  git checkout -b "$branch" "$tag"

  # cherry-pick the seal commit
  log "Cherry-picking seal commit onto $tag..."
  if ! git cherry-pick "$SEAL_COMMIT"; then
    # try auto-resolving the known conflict
    if auto_resolve_conflict; then
      # apply version-specific API fixups
      apply_version_fixups "$tag"
      git add typing/typecore.ml
      git add testsuite/tests/typing-seal/ 2>/dev/null || true
      # complete the cherry-pick with a non-interactive commit
      if ! git -c core.editor=true cherry-pick --continue; then
        error "Failed to complete cherry-pick after auto-resolution."
        git cherry-pick --abort 2>/dev/null || true
        git checkout - 2>/dev/null || git checkout trunk
        return 1
      fi
    else
      error "Cherry-pick failed and auto-resolution couldn't handle it."
      error ""
      error "Conflicting files:"
      git diff --name-only --diff-filter=U 2>/dev/null || true
      error ""
      error "To fix manually:"
      error "  git checkout $branch"
      error "  # edit the conflicting files"
      error "  git add typing/typecore.ml"
      error "  git cherry-pick --continue"
      error "  ./seal-port.sh port $tag   # re-run to build and tag"
      echo ""
      git cherry-pick --abort
      git checkout - 2>/dev/null || git checkout trunk
      return 1
    fi
  else
    # cherry-pick succeeded cleanly, but may still need API fixups
    apply_version_fixups "$tag"
    if ! git diff --quiet typing/typecore.ml 2>/dev/null; then
      git add typing/typecore.ml
      git commit --amend --no-edit 2>/dev/null || true
    fi
  fi

  # build
  log "Building OCaml ($tag)... this takes a few minutes"
  local build_cmd='make clean >/dev/null 2>&1; ./configure >/dev/null 2>&1 && make world >/dev/null 2>&1'
  if [ -n "$TIMEOUT_CMD" ]; then
    build_cmd="$TIMEOUT_CMD $BUILD_TIMEOUT bash -c '$build_cmd'"
  fi
  if ! eval "$build_cmd"; then
    error "Build failed for $tag."
    error ""
    error "This usually means an API difference we don't handle yet."
    error ""
    error "The branch '$branch' is left for you to investigate:"
    error "  git checkout $branch"
    error "  ./configure && make world   # see the actual error"
    git checkout - 2>/dev/null || git checkout trunk
    return 1
  fi

  # test
  log "Running seal tests..."
  if cd testsuite && make one TEST=tests/typing-seal/seal.ml >/dev/null 2>&1; then
    log "Tests passed!"
    cd ..
  else
    warn "Tests failed — expected output may differ in this version."
    warn ""
    warn "This is usually just formatting differences. To fix:"
    warn "  git checkout $branch"
    warn "  cd testsuite && make promote DIR=tests/typing-seal"
    warn "  git add tests/typing-seal/"
    warn "  git commit --amend --no-edit"
    warn "  ./seal-port.sh port $tag   # re-run to tag it"
    cd ..
    git checkout - 2>/dev/null || git checkout trunk
    return 1
  fi

  # tag it
  git tag "$sealed_tag"
  log "Created tag '$sealed_tag'"

  git checkout - 2>/dev/null || git checkout trunk
  log "Done with $tag"
  echo ""
}

# ---- Main --------------------------------------------------------

ensure_repo_root

case "${1:-help}" in
  setup)
    cmd_setup
    ;;
  fetch)
    cmd_fetch
    ;;
  sync)
    cmd_sync
    ;;
  port)
    shift
    cmd_port "$@"
    ;;
  status)
    cmd_status
    ;;
  push)
    cmd_push
    ;;
  help|--help|-h|"")
    echo "seal-port.sh — port the [%seal] patch to multiple OCaml versions"
    echo ""
    echo "Commands:"
    echo "  setup    Commit your [%seal] changes on a dedicated 'seal' branch"
    echo "  fetch    Download latest tags from upstream"
    echo "  sync     Update trunk from upstream and rebase seal on top"
    echo "  port     Cherry-pick [%seal] onto release tags (builds + tests)"
    echo "  status   Show all sealed branches and tags"
    echo "  push     Push everything to your GitHub fork"
    echo ""
    echo "Typical workflow:"
    echo "  1. git remote add upstream https://github.com/ocaml/ocaml.git"
    echo "  2. ./seal-port.sh setup              # commit your changes"
    echo "  3. ./seal-port.sh port 5.4.1         # port to a release"
    echo "  4. ./seal-port.sh push               # push to your fork"
    echo ""
    echo "  # later, when a new release comes out:"
    echo "  5. ./seal-port.sh fetch              # get new tags"
    echo "  6. ./seal-port.sh sync               # update trunk + seal"
    echo "  7. ./seal-port.sh port 5.5.0-beta1   # port to new release"
    echo "  8. ./seal-port.sh push"
    echo ""
    echo "  # check what you have:"
    echo "  9. ./seal-port.sh status"
    ;;
  *)
    error "Unknown command: $1"
    error "Run './seal-port.sh help' for usage."
    exit 1
    ;;
esac
