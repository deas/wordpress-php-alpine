#!/bin/sh
# Wrapper for the mysql/mariadb client binaries that wp-cli shells out to.
# Installed into /usr/local/bin under all six names; execs the real binary in
# /usr/bin with certificate verification switched off.
#
# WHY VERIFICATION IS OFF. The client in this image is MariaDB's (see the
# mariadb-client note in the Dockerfile) and MariaDB 11's client verifies the
# server certificate BY DEFAULT — `mariadb --help --verbose` reports
# `ssl-verify-server-cert TRUE`. MySQL's own client does not: its default
# `--ssl-mode=PREFERRED` encrypts without verifying. Against a stock MySQL 8,
# which auto-generates a self-signed CA at initialization
# (`auto_generate_certs=ON`) that is in no trust store, every one of these
# binaries therefore dies:
#
#   ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain
#
# That is not hypothetical and it went unnoticed for as long as it existed. The
# deployed sites run against MySQL 8.0, so the entire `wp db` family — export,
# import, cli, query, check, optimize, repair, the whole reason mariadb-client
# is in this image — could not run in production, while 40-integration stayed
# green because it points at mariadb:11. Measured 2026-08-19 against MySQL
# 8.0.46: `db query` and `db export` produced NO output and NO error because
# wp-cli sends it to stderr, and only `db check` showed the reason.
#
# WHY A WRAPPER AND NOT AN OPTION FILE. The obvious fix is
# `[client] ssl-verify-server-cert=0` in /etc/my.cnf.d/, which /etc/my.cnf picks
# up via its !includedir. It was tried first and it does nothing: wp-cli passes
# **--no-defaults** to every mysql command it builds, so no option file is read
# at all. Its `--defaults` flag does not rescue it either — the call that fails
# is wp-cli's own internal `get_sql_modes()` probe, which runs before your
# query and builds its own invocation. Verified both, 2026-08-19. A wrapper is
# the only place left that is guaranteed to be on the path of every call.
#
# THE FLAG GOES LAST, and that is deliberate: MariaDB requires --no-defaults to
# be the FIRST option, and wp-cli puts it there. Prepending ours would displace
# it. Appending after the database name was tested and parses fine.
#
# THIS DOES NOT DISABLE ENCRYPTION, which is the distinction that matters.
# `--skip-ssl` would also have silenced the error, by dropping the encryption
# instead of the check. With this flag the session is still TLSv1.3 — 41-mysql
# asserts a non-empty Ssl_cipher precisely so that a future "simplification" to
# --skip-ssl fails a test instead of quietly downgrading every deployment.
#
# It puts this client where MySQL's own client already is by default, rather
# than anywhere laxer than either.
exec "/usr/bin/${0##*/}" "$@" --ssl-verify-server-cert=0
