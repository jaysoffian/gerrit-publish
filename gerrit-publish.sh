#!/bin/bash
#
# This is gerrit-publish.sh
#
# Purpose: add a Change-Id footer to all commits between @{upstream} and HEAD,
# then publish the changes to the code-review system. If fmt is available, use
# it to reformat commit message to adhere to gerrit's sensibilities.
#
###################
# TODO:
#
# [ ] Rename to gerrit-client.sh
#
# [ ] Add various verbs:
#   1. publish - the default
#   2. checkout [change-id] - fetch the given change, create a branch for it
#      then switch to that branch. Good for examining someone else's change.
#   3. apply [change-id] - fetch the given change and apply it on top of HEAD.
#   4. rebase [change-id] - fetch the given change and rebase it.
#   5. merge [change-id] - fetch the given change, then merge it. Which should
#      be the first parent, the change or the branch?
#
# [ ] Try to make fmt not screw up footers such as "bug:", "git-svn-id:" etc.
#

VERSION="0.3"
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

# The tree must be really really clean.
if ! git update-index --ignore-submodules --refresh > /dev/null; then
        echo >&2 "Cannot publish: you have unstaged changes"
        git diff-files --name-status -r --ignore-submodules -- >&2
        exit 1
fi
diff=$(git diff-index --cached --name-status -r --ignore-submodules HEAD --)
case "$diff" in
?*)     echo >&2 "Cannot publish: your index contains uncommitted changes"
        echo >&2 "$diff"
        exit 1
        ;;
esac

headname=$(git rev-parse -q --verify --abbrev-ref HEAD --) ||
  die "Cannot determine current branch."

remote=$(git config branch.$headname.remote)
if ! test "$remote"; then
    echo "Cannot determine remote for $headname; guessing 'origin'"
    echo "If this is not correct, please set branch.$headname.remote"
    remote='origin'
fi

upstream=$(git rev-parse -q --verify --abbrev-ref @{upstream} -- 2>/dev/null)
if ! test "$upstream"; then
  upstream=$(git rev-parse -q --verify --abbrev-ref "$remote" --) ||
    die "Cannot determine upstream branch for $headname.
Please set branch.$headname.merge correctly."
  echo "Cannot determine upstream branch for $headname; guessing '$upstream'"
  echo "If this is not correct, please set branch.$headname.merge"
fi

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
if ! test "$force" && git name-rev --no-undefined \
    --refs="refs/remotes/$remote/*" HEAD >/dev/null 2>&1
then
    echo "Local branch $headname has already been merged to a branch on $remote."
    echo "Use --force to re-publish anyway."
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
