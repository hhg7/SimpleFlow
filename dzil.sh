#!/bin/sh
set -e

# The version dzil is about to build, read from the one place it is set:
# dist.ini's [VersionFromModule] takes it from this same line. Needed below to
# name the tarball to list and the build to record in the commit message.
VERSION=$(sed -n 's/^our $VERSION = .\([0-9][0-9.]*\).;.*$/\1/p' lib/SimpleFlow.pm)
if [ -z "$VERSION" ]; then
	echo "dzil.sh: no \$VERSION found in lib/SimpleFlow.pm" >&2
	exit 1
fi

perl md2pod.pl
dzil clean
dzil build
# Score the tarball dzil just built: the md2pod.pl run above happened before
# `dzil clean`, so it could only see the previous release's tarball.
perl md2pod.pl --kwalitee-only

echo "==== tarball contents (verify: no .c/.o/.dll/.bs/.gcda/blib/) ===="
tar tzf "SimpleFlow-$VERSION.tar.gz"

# The commit comes last so that one run finishes the job. `dzil clean` deletes
# the previous release's directory and tarball, both of them tracked, and
# `dzil build` writes the new pair as untracked files -- so committing before
# the build, as this script did until 2026-09-12, could never see either, and
# left them for the next run to sweep up. That is why the shipped "Update
# generated docs" commits carry the deletion of the release before them.
#
# -A is confined to the SimpleFlow-* pathspec so that it stages exactly those
# additions and deletions; -a then takes the tracked files md2pod.pl rewrote.
# A bare `git add -A` would also sweep up whatever else is sitting untracked in
# the root -- CLAUDE.md, a stray cover_db, editor droppings.
git add -A -- 'SimpleFlow-*'
git commit -am "Update generated docs; build $VERSION" || true # an empty commit is not an error

echo "If that looks clean, run: dzil release"
