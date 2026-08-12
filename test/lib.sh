#!/bin/sh
# Tiny assertion harness. POSIX sh, no dependencies — the same reason the
# entrypoint is sh: this has to run on a GitHub runner, on a laptop, and inside
# whatever minimal container someone reaches for, without an install step.
#
# If this ever outgrows counters and three assertions, replace it with
# bats-core rather than growing it. It is not trying to be a framework.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_SUITE=""

# The image under test. CI exports IMAGE; locally it defaults to what the
# Makefile builds.
IMAGE="${IMAGE:-deas/wordpress:8.5.wip-fpm-alpine}"

suite() {
    CURRENT_SUITE="$1"
    printf '\n\033[1m# %s\033[0m\n' "$1"
}

_pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  \033[32mok\033[0m   %s\n' "$1"
}

_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    [ -n "$2" ] && printf '       %s\n' "$2"
    return 0
}

# assert_eq <expected> <actual> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then
        _pass "$3"
    else
        _fail "$3" "expected [$1], got [$2]"
    fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
    case "$1" in
        *"$2"*) _pass "$3" ;;
        *) _fail "$3" "expected to find [$2]" ;;
    esac
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
    case "$1" in
        *"$2"*) _fail "$3" "did not expect to find [$2]" ;;
        *) _pass "$3" ;;
    esac
}

# Run a PHP snippet in the image and echo ONLY its marked output.
#
# The entrypoint runs `printenv` under `set -x`, so raw stdout is full of
# environment and trace lines — grepping it for e.g. "xdebug" matches
# PHP_XDEBUG_ENABLED=0 and reports the opposite of the truth. Every probe here
# therefore prints a unique marker and only the marked line is returned. This
# cost one wrong answer while writing these tests; do not "simplify" it away.
#
# Usage: php_probe '<php code echoing a value>' [docker run args...]
php_probe() {
    _code="$1"
    shift
    docker run --rm -e WP_DB_PASS=probe "$@" "$IMAGE" \
        php -r "echo \"__PROBE__\", ($_code), \"__END__\n\";" 2>/dev/null |
        sed -n 's/.*__PROBE__\(.*\)__END__.*/\1/p' | head -1
}

# Shell one-liner, entrypoint BYPASSED (--entrypoint sh). Use for inspecting
# what the build produced: faster, and free of the entrypoint's `set -x` noise.
sh_probe() {
    _cmd="$1"
    shift
    docker run --rm --entrypoint sh -e WP_DB_PASS=probe "$@" "$IMAGE" \
        -c "printf '__PROBE__%s__END__\n' \"\$($_cmd)\"" 2>/dev/null |
        sed -n 's/.*__PROBE__\(.*\)__END__.*/\1/p' | head -1
}

# Shell one-liner, entrypoint RUN FIRST (sh is the command, not the entrypoint).
#
# The distinction is the whole game for anything the entrypoint DOES — the uid
# remap, ssmtp.conf, the xdebug ini. Probing those with sh_probe reports the
# unmodified image and every assertion fails for the wrong reason. That mistake
# produced five confident false failures the first time these tests ran.
ep_probe() {
    _cmd="$1"
    shift
    docker run --rm -e WP_DB_PASS=probe "$@" "$IMAGE" \
        sh -c "printf '__PROBE__%s__END__\n' \"\$($_cmd)\"" 2>/dev/null |
        sed -n 's/.*__PROBE__\(.*\)__END__.*/\1/p' | head -1
}

# ---------------------------------------------------------------- batching --
#
# A container start costs ~3.8s here, and it dominates everything — the harness
# itself is not measurable next to it. So checks that only INSPECT the image
# (which is most of them) share one container instead of paying that each.
#
# The exceptions are real and stay one-container-per-case: anything that depends
# on the environment a container was CREATED with, i.e. the xdebug matrix and
# the uid remap. Those cannot be batched by definition.
#
# Usage — the script arrives on stdin, so a quoted heredoc keeps every quote
# intact and nothing is expanded host-side:
#
#     batch_run <<'PROBE'
#     emit answer "$(compute-something)"
#     php -r 'printf("__P__pi=%s__E__\n", M_PI);'
#     PROBE
#     assert_eq "42" "$(batch_get answer)" "..."
#
# Shell values go through emit; PHP can print the marker lines itself, which
# avoids a second layer of quoting. Marker discipline is the same as the single
# probes and for the same reason — see php_probe.
BATCH_FILE=""

batch_run() {
    [ -n "$BATCH_FILE" ] && rm -f "$BATCH_FILE"
    BATCH_FILE=$(mktemp)
    {
        printf 'emit() { printf "__P__%%s=%%s__E__\\n" "$1" "$2"; }\n'
        cat
    } | docker run --rm -i --entrypoint sh -e WP_DB_PASS=probe "$@" "$IMAGE" -s 2>/dev/null |
        sed -n 's/.*__P__\(.*\)__E__.*/\1/p' >"$BATCH_FILE"
}

batch_get() {
    sed -n "s/^$1=//p" "$BATCH_FILE" | head -1
}

summary() {
    printf '\n'
    if [ "$TESTS_FAILED" -eq 0 ]; then
        printf '\033[32m%s tests, 0 failures\033[0m\n' "$TESTS_RUN"
        return 0
    fi
    printf '\033[31m%s tests, %s failures\033[0m\n' "$TESTS_RUN" "$TESTS_FAILED"
    return 1
}
