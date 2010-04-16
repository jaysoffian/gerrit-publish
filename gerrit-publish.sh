#!/bin/bash
#
# This is gerrit-publish.sh
#
# Purpose: add a Change-Id footer to all commits between @{upstream} and HEAD,
# then publish the changes to the code-review system. If fmt is available, use
# it to reformat commit message to adhere to gerrit's sensibilities.
#

VERSION="0.2"
OPTIONS_SPEC="\
gerrit-publish.sh [option...]
--
force!     Try publishing even if the branch has already been merged remotely
h,help!    This message
no-fetch!  Don't fetch before checking if branch has been merged remotely
no-fmt!    Don't reformat commit messages
no-push!   Prepare branch for publishing, but don't actually publish it
version!   Version $VERSION
"

SUBDIRECTORY_OK=1
. "$(git --exec-path)/git-sh-setup"
require_work_tree
cd_to_toplevel

dofetch=1
dopush=1
force=
usefmt=1

while test $# != 0; do
  case "$1" in
    --force) force=1; dofetch= ;; # force implies nofetch
    --no-fetch) dofetch= ;;
    --no-fmt) usefmt= ;;
    --no-push) dopush= ;;
    --version) echo "$VERSION";  exit 0;;
  esac
  shift
done

git diff-index --quiet HEAD -- ||
  die "Working tree is dirty; please commit or stash before proceeding."

headname=$(git rev-parse -q --verify --abbrev-ref HEAD --) ||
  die "Cannot determine current branch."

upstream=$(git rev-parse -q --verify --abbrev-ref @{upstream} --) ||
  die "Cannot determine upstream branch for $headname.
Please set branch.$headname.merge and branch.$headname.remote correctly."

remote=$(git config branch.$headname.remote) ||
  die "Cannot determine remote for $headname.
Please set branch.$headname.remote correctly."

test "$remote" = "." &&
  die "Cannot use local repo ('.') as the remote.
Please set branch.$headname.remote to a real remote."

destname=${upstream##$remote/}

status() {
  echo "~~~ $@"
}

# Fetch
if test "$dofetch"; then
  status "Fetching from $remote"
  git fetch "$remote"
fi

# Check whether the topic has already been merged
if ! test "$force" && git name-rev --no-undefined --refs="refs/remotes/$remote/*" \
  HEAD >/dev/null 2>&1
then
    echo "Local branch $headname has already been merged to a branch on $remote."
    echo "Use --force if you want to attempt publishing anyway."
    exit 1
fi

# See if we need to add the Change-Id footer
status "Checking commit messages for Change-Id footer"
x05="[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
x40="$x05$x05$x05$x05$x05$x05$x05$x05"
have=$(git rev-list --grep="^Change-Id: I$x40$" "${upstream}..")
nothave=$(git rev-list "${upstream}..")

# Use filter-branch to rewrite as needed
if ! test "$have" = "$nothave"; then
  status "Adding Change-Id footer to commit messages"
  export usefmt x40
  git update-ref ORIG_HEAD HEAD # filter-branch should do this...
  git filter-branch --msg-filter '
    if test "$usefmt" && test "$(type -p fmt)"; then
      fmt="fmt -w 70"
    else
      fmt=cat
    fi
    (
      has_change_id=
      firstline=1
      while read line
      do
        case "$line" in
          "Change-Id: I"$x40) has_change_id=1 ;;
        esac
        if test "$usefmt" && test "$firstline" && test ${#line} -gt 65; then
          echo "${line:0:62}..."
          echo
          echo "$line"
        else
          echo "$line"
        fi
        firstline=
      done
      if ! test "$has_change_id"; then
        echo
        echo "Change-Id: I$GIT_COMMIT"
      fi
    ) | $fmt
  ' --original refs/git-publish -f "${upstream}.." 2>/dev/null

  # Cleanup after filter-branch
  eval $(git for-each-ref --shell --format="git update-ref -d %(refname)" refs/git-publish/)

  # Make sure we didn't break anything
  if ! git diff --quiet ORIG_HEAD HEAD; then
    status "Unexpected changes after running filter-branch; reverting HEAD"
    git reset --hard ORIG_HEAD
    exit 1
  fi
fi

# Publish
if test "$dopush"; then
  status "Publishing commits"
  echo + git push "$remote" "HEAD:refs/for/$destname"
  git push "$remote" "HEAD:refs/for/$destname"
else
  echo "To publish this topic use:"
  echo git push "$remote" "HEAD:refs/for/$destname"
fi
