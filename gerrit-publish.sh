#!/bin/bash
#
# This is gerrit-publish.sh
#
# Purpose: add a Change-Id footer to all commits between @{upstream} and HEAD,
# then publish the changes to the code-review system. If fmt is available, use
# it to reformat commit message to adhere to gerrit's sensibilities.
#
#
# TODO:
# . Add --preview (maybe)
# . Add --no-fmt
# . Running fmt for each commit message line is terribly inefficient
# . Perhaps this whole thing should be written in Python instead

VERSION="0.1"

USAGE="[-h|--help] [--version]"
LONG_USAGE="Usage: gerrit-publish.sh [-h]"
OPTIONS_SPEC="gerrit-publish.sh $USAGE
--
h,help  no help, just run it!
version $VERSION
"

SUBDIRECTORY_OK=1
. "$(git --exec-path)/git-sh-setup"
require_work_tree
cd_to_toplevel

while test $# != 0; do
  case "$1" in
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

# See if we need to add the Change-Id footer
x05="[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
x40="$x05$x05$x05$x05$x05$x05$x05$x05"
have=$(git rev-list --grep="^Change-Id: I$x40$" "${upstream}..")
nothave=$(git rev-list "${upstream}..")

status() {
  echo "==== $@ ===="
}

if ! test "$have" = "$nothave"; then
  status "Adding Change-Id to commit messages"
  git update-ref ORIG_HEAD HEAD # filter-branch should do this...
  git filter-branch --msg-filter '
    x05="[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
    x40="$x05$x05$x05$x05$x05$x05$x05$x05"
    usefmt=$(type -p fmt)
    has_change_id=0
    linenum=0
    while read line
    do
      case "$line" in
        "Change-Id: I"$x40) has_change_id=1 ;;
      esac
      if test "$usefmt"; then
        if test $linenum -eq 0; then
          if test ${#line} -gt 65; then
            echo "${line:0:62}..."
            echo
            echo "$line" | fmt -w 70
          else
            echo "$line"
          fi
        else
          if test ${#line} -gt 70; then
            echo "$line" | fmt -w 70
          else
            echo "$line"
          fi
        fi
      else
        echo "$line"
      fi
      ((linenum++))
    done
    if test $has_change_id -eq 0
    then
      echo; echo "Change-Id: I$GIT_COMMIT"
    fi
  ' --original refs/git-publish -f "${upstream}.." 2>/dev/null

  # Cleanup after filter-branch
  eval $(git for-each-ref --shell --format="git update-ref -d %(refname)" refs/git-publish/)

  # Make sure we didn't break anything
  if ! git diff --quiet ORIG_HEAD HEAD; then
    status "Unexpected changes; reverting HEAD"
    git reset --hard ORIG_HEAD
    exit 1
  fi
fi

# Publish
status "Publishing commits"
echo + git push "$remote" "HEAD:refs/for/$destname"
git push "$remote" "HEAD:refs/for/$destname"

