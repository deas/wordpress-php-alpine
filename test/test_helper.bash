#!/usr/bin/env bash
# Shared setup for the .bats suites.
#
# bats-support and bats-assert are VENDORED under test/lib/ rather than
# installed: neither is packaged on Arch, and a test suite that only runs where
# someone remembered to install two helper libraries is a test suite that stops
# being run. They are small (48K + 136K) and pinned by being copied.

load "lib/bats-support/load"
load "lib/bats-assert/load"

# The image under test. CI exports IMAGE; locally it defaults to what the
# Makefile builds. Tests assert against an image that ALREADY EXISTS and never
# build one, so the same command checks a local build and a published tag.
export IMAGE="${IMAGE:-deas/wordpress:8.5.wip-fpm-alpine}"

# --------------------------------------------------------------- probing ----
#
# Every probe prints a marker and only the marked line is read back.
#
# The entrypoint runs `printenv` under `set -x`, so raw stdout is full of
# environment and trace lines — grepping it for e.g. "xdebug" matches
# PHP_XDEBUG_ENABLED=0 and reports the OPPOSITE of the truth. This cost one
# wrong answer while writing these tests; do not "simplify" it away.
_unmark() { sed -n 's/.*__P__\(.*\)__E__.*/\1/p' | head -1; }

# Run a PHP snippet, entrypoint RUN FIRST.
php_probe() {
    local code="$1"
    shift
    docker run --rm -e WP_DB_PASS=probe "$@" "$IMAGE" \
        php -r "echo \"__P__\", ($code), \"__E__\n\";" 2>/dev/null | _unmark
}

# Shell one-liner, entrypoint BYPASSED (--entrypoint sh). For inspecting what
# the BUILD produced: faster, and free of the entrypoint's trace noise.
sh_probe() {
    local cmd="$1"
    shift
    docker run --rm --entrypoint sh -e WP_DB_PASS=probe "$@" "$IMAGE" \
        -c "printf '__P__%s__E__\n' \"\$($cmd)\"" 2>/dev/null | _unmark
}

# Shell one-liner, entrypoint RUN FIRST (sh is the command, not the entrypoint).
#
# The sh_probe/ep_probe distinction is the whole game for anything the
# entrypoint DOES — the uid remap, ssmtp.conf, the xdebug ini. Probing those
# with sh_probe inspects an unmodified image and fails every assertion for the
# wrong reason; it produced five confident false failures the first time these
# tests ran.
ep_probe() {
    local cmd="$1"
    shift
    docker run --rm -e WP_DB_PASS=probe "$@" "$IMAGE" \
        sh -c "printf '__P__%s__E__\n' \"\$($cmd)\"" 2>/dev/null | _unmark
}

# -------------------------------------------------------------- batching ----
#
# A container start costs ~3.8s and dominates everything; the assertions
# themselves are not measurable next to it. So checks that only INSPECT the
# image share ONE container, run from setup_file, with results read back per
# test. That took 10-image from ~57s to 1s.
#
# What is deliberately NOT batched, because it cannot be: anything whose result
# depends on the environment the container was CREATED with — the xdebug truth
# table and the uid remap. Those are one container per case by definition, and
# they are what --jobs is for.
#
# The script arrives on the container's stdin from a QUOTED heredoc, so nothing
# is expanded host-side and embedded PHP keeps its own quotes.
batch_run() {
    {
        printf 'emit() { printf "__P__%%s=%%s__E__\\n" "$1" "$2"; }\n'
        cat
    } | docker run --rm -i --entrypoint sh -e WP_DB_PASS=probe "$@" "$IMAGE" -s 2>/dev/null |
        sed -n 's/.*__P__\(.*\)__E__.*/\1/p' >"$BATS_FILE_TMPDIR/batch"
}

batch_get() { sed -n "s/^$1=//p" "$BATS_FILE_TMPDIR/batch" | head -1; }
