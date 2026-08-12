#!/bin/sh
# Run the image test suites.
#
#   make test                       everything, against the Makefile's IMAGE
#   IMAGE=ghcr.io/deas/wordpress:latest test/run.sh
#   SKIP_INTEGRATION=1 test/run.sh  fast suites only, no database
#   test/run.sh 20                  just the suites whose file starts with 20
#
# Tests assert against an image that ALREADY EXISTS — they never build one, so
# the same command checks a local build and a published tag.

# -u only, deliberately NOT -e: a test runner must report every failure, not
# abort on the first command that returns non-zero. (And under -e a probe like
# `x=$(cmd; echo $?)` exits the substitution before it can report the code,
# which silently truncates the run — that is how this comment came to exist.)
set -u

cd "$(dirname "$0")"
. ./lib.sh

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'image not found: %s\n' "$IMAGE" >&2
    printf 'build it first (make docker-build) or set IMAGE=<tag>\n' >&2
    exit 2
fi

printf 'testing \033[1m%s\033[0m\n' "$IMAGE"

filter="${1:-}"
for f in [0-9]*.sh; do
    case "$f" in
        ${filter}*) . "./$f" ;;
    esac
done

summary
