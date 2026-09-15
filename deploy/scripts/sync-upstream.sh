#!/usr/bin/env bash
# Manual mirror of .github/workflows/sync-upstream.yml. Runs in Git Bash on Windows, bash elsewhere.
#
#   deploy/scripts/sync-upstream.sh            # fetch upstream, ff main, merge main into docker, push both
#   deploy/scripts/sync-upstream.sh --no-push  # do everything locally, push nothing
#   deploy/scripts/sync-upstream.sh --abort    # on conflict, abort the merge instead of leaving it open
#
# Contract: `main` is a pure fast-forward mirror of upstream; `docker` = main + deploy/** + two workflows.
set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
WORK_BRANCH="${WORK_BRANCH:-docker}"
ALLOWED_RE='^(deploy/|\.github/workflows/(sync-upstream|docker-image)\.yml$)'

PUSH=1; ABORT_ON_CONFLICT=0
for a in "$@"; do
  case "$a" in
    --no-push) PUSH=0 ;;
    --abort)   ABORT_ON_CONFLICT=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

root="$(git rev-parse --show-toplevel)" || die "run inside the repository"
cd "$root"

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes; commit or stash first"
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || die "remote '$UPSTREAM_REMOTE' missing: git remote add upstream https://github.com/bilawalsidhu/gods-eye-view.git"
[ "$(git config core.autocrlf || true)" = "false" ] || echo "warning: core.autocrlf is not 'false' for this repo (the eol=lf attribute should still win)"

log "fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH and $ORIGIN_REMOTE"
git fetch --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
git fetch --no-tags "$ORIGIN_REMOTE" "$MIRROR_BRANCH" "$WORK_BRANCH"
UP="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; UP_SHORT="$(git rev-parse --short "$UP")"

# --- 1. fast-forward the mirror branch (local ref + origin) without checking it out --------------
log "mirror: $MIRROR_BRANCH -> upstream $UP_SHORT"
if git show-ref --verify --quiet "refs/heads/$MIRROR_BRANCH"; then
  git merge-base --is-ancestor "$MIRROR_BRANCH" "$UP" || die "local $MIRROR_BRANCH has commits not in upstream; it must stay a pure mirror"
fi
if [ "$(git rev-parse --abbrev-ref HEAD)" = "$MIRROR_BRANCH" ]; then
  git merge --ff-only "$UP"
else
  git branch -f "$MIRROR_BRANCH" "$UP"
fi
if git merge-base --is-ancestor "$ORIGIN_REMOTE/$MIRROR_BRANCH" "$UP"; then
  if [ "$PUSH" = 1 ]; then git push "$ORIGIN_REMOTE" "$UP:refs/heads/$MIRROR_BRANCH"; fi
else
  die "$ORIGIN_REMOTE/$MIRROR_BRANCH has diverged from upstream. Inspect: git log $UP..$ORIGIN_REMOTE/$MIRROR_BRANCH ; then: git push --force-with-lease=$MIRROR_BRANCH $ORIGIN_REMOTE $UP:$MIRROR_BRANCH"
fi

# --- 2. merge upstream into the work branch -----------------------------------------------------
log "checking out $WORK_BRANCH"
git checkout -q "$WORK_BRANCH"
git merge --ff-only "$ORIGIN_REMOTE/$WORK_BRANCH" 2>/dev/null || echo "note: local $WORK_BRANCH is ahead of $ORIGIN_REMOTE (fine)"

if git merge-base --is-ancestor "$UP" HEAD; then
  log "$WORK_BRANCH already contains upstream $UP_SHORT; nothing to merge"
else
  log "merging upstream $UP_SHORT into $WORK_BRANCH (--no-ff)"
  if ! git merge --no-ff --no-edit -m "chore(sync): merge upstream $UPSTREAM_BRANCH @ $UP_SHORT into $WORK_BRANCH" "$UP"; then
    echo
    echo "CONFLICTS:"; git diff --name-only --diff-filter=U | sed 's/^/  /'
    if [ "$ABORT_ON_CONFLICT" = 1 ]; then git merge --abort; die "merge aborted (--abort)"; fi
    cat <<'HELP'

Merge left open. Resolve, then:  git add -A && git commit --no-edit && git push origin docker
  - files OUTSIDE deploy/ : take upstream verbatim ->  git checkout --theirs -- <path>
  - files under deploy/   : decide by hand
HELP
    exit 1
  fi
fi

# --- 3. overlay guard: docker may only differ from upstream under deploy/ and the two workflows --
bad="$(git diff --name-only "$UP" HEAD | grep -Ev "$ALLOWED_RE" || true)"
if [ -n "$bad" ]; then
  echo "$bad" | sed 's/^/  /'
  die "docker modifies upstream-owned files (above). Restore with: git checkout $UP -- <path>; then commit."
fi

# --- 4. push ------------------------------------------------------------------------------------
if [ "$PUSH" = 1 ]; then
  log "pushing $WORK_BRANCH (a user push triggers .github/workflows/docker-image.yml automatically)"
  git push "$ORIGIN_REMOTE" "HEAD:refs/heads/$WORK_BRANCH"
else
  log "--no-push: local branches updated, nothing pushed"
fi
log "done: $MIRROR_BRANCH=$UP_SHORT, $WORK_BRANCH=$(git rev-parse --short HEAD)"
