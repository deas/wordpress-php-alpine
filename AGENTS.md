# AGENTS.md

## What this is

A single container image (`ghcr.io/deas/wordpress`, `php:8.5-fpm-alpine` base) that runs WordPress under PHP-FPM. There is no application code here — WordPress itself is downloaded at container start. The repo is the _execution environment_: PHP extensions, `wp-cli`, ssmtp mail, xdebug, and a boot script that provisions/repairs a WordPress install from environment variables.

## Commands

```sh
make                 # help (default goal), lists targets
make docker-build    # docker build --no-cache -t deas/wordpress:8.5.wip-fpm-alpine .
```

```sh
make test            # bats, parallel (--jobs nproc); needs docker + bats
make test-fast       # same, minus the suite that needs a database
bats test/20-xdebug.bats          # one file
IMAGE=ghcr.io/deas/wordpress:latest make test   # check a published tag
```

**Tests** are bats-core under `test/`, 75 assertions in five files. They assert against an image that **already exists** and never build one, which is why the same command checks a local build and whatever is live. `make act-build` is still a `false` stub.

That `IMAGE=… make test` line only works because `IMAGE` is assigned with **`?=`**. It was `:=`, and a `:=` in a Makefile beats the environment — so the documented invocation silently tested the local image, went green, and never pulled the tag it named. Keep it `?=`.

- `10-image` extensions, gd flags, imagick delegates, ICU data, binaries, build-hygiene guards · `20-xdebug` the toggle truth table · `30-entrypoint` WP_DB_PASS guard, uid remap, ssmtp, the salt contract · `40-integration` empty volume + MariaDB → installed WordPress, then `wp db` against it · `41-mysql` the same `wp db` subcommands against **MySQL**, which is what the deployed sites run and what 40 does not cover.
- `bats-support` / `bats-assert` are **vendored** in `test/lib`, not installed — a suite that only runs where two helper libraries happen to be installed stops being run.
- **Three conventions exist because breaking them produces false results, not failures:**
  - Every probe prints a marker and only the marked line is read back. The entrypoint runs `printenv` under `set -x`, so grepping raw output for `xdebug` matches `PHP_XDEBUG_ENABLED=0` and reports the opposite of the truth.
  - **Probes must not merge stderr.** The `set -x` trace echoes the command being exec'd, so a probe's own `printf` format appears *before* its output and extraction returns the literal `%s`. This once made "salts are stable across a restart" compare two degraded probes and pass having checked nothing.
  - `sh_probe` bypasses the entrypoint (`--entrypoint sh`), `ep_probe` runs through it. Probing entrypoint behaviour with the former inspects an unmodified image and fails every assertion for the wrong reason.
- What is batched and what is not is a deliberate split: checks that only **inspect** the image share one container (`setup_file`), which took `10-image` from ~57s to 1s. Anything depending on the environment a container was **created** with — the xdebug matrix, the uid remap — is one container per case and is what `--jobs` is for. `40-integration` and `41-mysql` opt out of parallelism via `BATS_NO_PARALLELIZE_WITHIN_FILE`, since their tests share a volume and build on each other.

## Architecture

**Build (`Dockerfile`)** — installs gd (jpeg/freetype/webp/avif), zip, mysqli, exif, intl, imagick, xdebug, and `wp` (wp-cli phar) into `/usr/local/bin`. `contentreich.ini` (dropped into `conf.d`) points `mysqli.default_socket` at `/var/run/mysqld/mysqld.sock` so a socket mount works.

Six things about this layer are load-bearing and easy to undo by accident:

- **`opcache` is NOT in the ext-install list.** As of PHP 8.5 the official image compiles it in statically, so `docker-php-ext-install opcache` builds no module and fails the layer with `cp: can't stat 'modules/*'`. It is still loaded — the untouched base already reports `Zend OPcache` in `php -m`. Adding it back breaks the build outright.
- **No `edge/community` repository.** It used to be added "as a quick hack to get usermod/groupmod from shadow", and it was a standing hazard: with edge in the list, any apk resolution may pull an edge package onto a stable base. `shadow` is in `v3.24/community`, which the base already enables.
- **Build deps are a deleted virtual package.** The `-dev` headers used to be installed as `.persistent-deps` and never removed, so they shipped to production — weight, plus CVE surface that `cve-scan.yml` then reported against.
- **`exif` / `intl` / `imagick` answer WordPress's own Site Health**, which listed all three as missing optional modules. `imagick` is the one taken on a calculated risk: Alpine 3.24 ships ImageMagick 7.1.2-27 marked *(Beta)*, and installing it **changes which image editor WordPress picks** — on contentreich it moved from GD to `EWWWIO_Imagick_Editor`. Back it out by dropping the module plus the `imagemagick`/`imagemagick-dev` packages.
- **`mariadb-client` is there for wp-cli, and `mysqli` does not substitute for it.** The whole `wp db` family (`export`, `import`, `cli`, `query`, `check`, `optimize`, `repair`) shells **out** to the `mysql`/`mysqldump`/`mysqlcheck` binaries rather than using the PHP connection, so without the package wp-cli shipped with a command group that could not run — `wp cli info` printed `MySQL binary:` followed by nothing. Costs ~39 MB (`mariadb-client` 37 + `mariadb-common` 2; every other dependency is already pulled in by the base or by `shadow`). Eight ~4.7 MB binaries are nearly all of that and only three are used here, but **do not prune files out of an installed apk package** to reclaim the rest: apk restores them on the next upgrade, so the saving reverts silently while the pruning line stays in the `Dockerfile` looking effective. Client major tracks the server (`mariadb:11`), which is what keeps `mysqldump` output loadable; `10-image` asserts both the binaries and that wp-cli *resolves* one, and `40-integration` runs `wp db query/export/check` against the live database.

- **The client is MariaDB's and the servers are MySQL, and that broke every `wp db` command in production.** MariaDB 11's client verifies the server certificate by default (`ssl-verify-server-cert TRUE`); MySQL's own client does not (`--ssl-mode=PREFERRED` encrypts without verifying). A stock MySQL 8 auto-generates a self-signed CA at initialization, so the whole `wp db` family died with `ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain` — while `40-integration` stayed green, because it points at `mariadb:11`. **A suite that only tests the engine you do not deploy is the shape of this bug**, and `41-mysql` exists to close it.
  - `mysql-tls-wrapper.sh` is the fix: it shadows all six client names in `/usr/local/bin` (which precedes `/usr/bin`) and appends `--ssl-verify-server-cert=0`. **An option file cannot work** — wp-cli passes `--no-defaults` to every mysql command it builds, so `/etc/my.cnf.d/*` is never read, and its `--defaults` flag does not help either because the failing call is wp-cli's internal `get_sql_modes()` probe. Both were tried first; the script records it.
  - **The flag goes LAST.** MariaDB requires `--no-defaults` to be the first option and wp-cli puts it there, so prepending ours would displace it.
  - It does **not** disable encryption — the session is still TLSv1.3. `--skip-ssl` would silence the same error by dropping the encryption instead of the check, which is why `41-mysql` asserts a non-empty `Ssl_cipher`. That assertion is the only thing separating the two, so read it before touching the wrapper.
  - **KNOWN LIMITATION, not fixed: `caching_sha2_password`.** Alpine's `mariadb-client` ships an EMPTY `/usr/lib/mariadb/plugin`, so a MySQL 8 user on the default auth plugin fails with `Plugin caching_sha2_password could not be loaded` no matter what TLS does. It does not bite today because all four WordPress users on the live host use `mysql_native_password` (measured 2026-08-19), which is why `41-mysql` starts its server with `--default-authentication-plugin=mysql_native_password` — that is production fidelity, not a workaround for the certificate problem. A MySQL that ever moves those users to the default plugin puts `wp db` back out of action.
  - **Two tests, and they are not redundant.** `41-mysql` is the proof — a real MySQL server, a real handshake, the connection actually succeeding. `10-image` carries a ~0s canary that asks each of the six binaries `--no-defaults --print-defaults`, so a dropped wrapper fails on every run including `make test-fast`. **`--no-defaults` is the whole point of that probe**: without it, the check reports the flag from any option file and would have certified the broken first attempt. `--help --verbose` is the other tempting shortcut and fails the opposite way — it reports `ssl-verify-server-cert TRUE` even through the working wrapper, because it reflects defaults and option files but never the command line. Neither shortcut can tell "configured" from "used", which is exactly where this bug lived, so neither replaces `41-mysql`.
  - Cosmetic consequence: `wp cli info` now reports the wrapper path and its `MySQL version:` line gains a `/usr/bin/mariadb from ` prefix. `10-image`'s assertions are a leading `/` and a `11.x-MariaDB` substring, so both still hold.
- **The wp-cli download is `curl -f` and is smoke-tested in the same layer.** Without `--fail`, curl exits `0` on an HTTP error and writes the error **body** to the output file — a transient GitHub 429 installs a 199-byte "Too Many Requests" page as `/usr/local/bin/wp`: executable, present, and dead. That is not hypothetical, it happened while adding `mariadb-client`, and the build went green. `--retry-all-errors` makes curl retry the 429 instead of merely refusing it, and `wp --allow-root --version` in the same `RUN` fails the **layer**, so a bad download cannot reach a test or a registry. Note which test caught it and which did not: `binary present: wp` is `command -v` and passed, "wp-cli actually runs, not merely exists" is what went red.

**Xdebug is present but NOT loaded by default**, and that is the whole point of how it is packaged. The build generates the ini the normal way and then moves it *out* of `conf.d` to `/usr/local/etc/php/xdebug.ini.available`; `entrypoint.sh` copies it back only when `PHP_XDEBUG_ENABLED` matches an explicit allow-list (`1|true|yes|on`, any case). It previously appended `zend_extension=` to `php.ini` itself, so production carried a loaded debugger with no way to switch it off and every PHP notice came out wrapped in a ten-frame stack trace — on stdout, where wp-cli output is parsed.

- **The allow-list is not fussiness.** `docker-compose.yml` on the consuming side passes `PHP_XDEBUG_ENABLED=0` as its *default*; a `[ -n "$VAR" ]` test would load the debugger on every production container. Same family of trap as the `(bool) getenv()` one in `wp-config-template.php`, where `'0'` is true.
- **Mode and client host/port need no variable of ours.** Xdebug 3 reads `XDEBUG_MODE` and `XDEBUG_CONFIG` from the environment itself (`XDEBUG_MODE=profile`, `XDEBUG_CONFIG="client_host=host.docker.internal client_port=9003"`). `PHP_XDEBUG_REMOTE_PORT` is honoured only because the compose files already carry it.
- The staged ini defaults to `start_with_request=trigger`, so "enabled" does not mean "slow" — Xdebug stays dormant until a request carries `XDEBUG_TRIGGER`. Default client port is **9003** (the Xdebug 3 default, what IDEs expect), not 9000/9100.
- An `env_file` is read when the container is **created**, so toggling needs a recreate, not a restart.

**Volumes / paths** — `WORKDIR` is `/usr/share/wordpress`; `EXTRACT_DIR=..` in the entrypoint therefore resolves to `/usr/share`, and the tarball unpacks to `/usr/share/wordpress`. `${EXTRACT_DIR}/wordpress` and the working dir are the same directory — keep that in mind when editing paths. `/usr/share/wordpress` and `/var/log/www` are `VOLUME`s.

**Boot (`entrypoint.sh`)**, in order:

1. `printenv` (with `set -x`) — the container log deliberately dumps the full environment, credentials included.
2. Fails hard if `WP_DB_PASS` is unset.
3. If no WordPress present → fetch the current version from `api.wordpress.org` and untar it. **`elif`** an SQL dump exists at `${IMPORT_SRC}/wordpress.sql` (default `/usr/share/wordpress-import`) → pipe it through `execute-statements-mysql.php`, then, if `WORDPRESS_HOME` is set, run the site rename. Import only happens on an _existing_ install; a fresh install never imports on the same run.
4. Copies `wp-config-template.php` → `wp-config.php` when missing.
5. Sets the 8 auth keys/salts in `wp-config.php` via `sed`, **idempotently**. Per key: `WORDPRESS_<KEY>` set (e.g. `WORDPRESS_AUTH_KEY`) → applied on every boot; still carrying the template's `put your unique phrase here` → generated once; anything else → left alone.
   - The idempotence is the point, not a refinement. This loop runs on every container start and a salt is the key every auth cookie and nonce is signed with, so rewriting a live one logs every user out. That is what the deployed sites suffered, and why contentreich-wordpress deleted the salt defines from its own `wp-config.php` to defend itself. A `wp-config.php` with no salt defines must therefore stay untouched — that is a cross-repo contract, covered by `test/30-entrypoint.sh`.
   - `set_config()` uses **no backreferences and no `\s`**. The original regex used both, which are GNU sed; this image is Alpine, so `sed` is busybox, which does not implement backreferences inside an ERE pattern — the substitution matched nothing and the entire salt rewrite was a silent no-op for as long as the image has been on Alpine. Every fresh install therefore ran with the literal placeholder as all eight secrets. Reduced: `echo xx | sed -r 's/(x)\1/M/'` prints `xx`.
6. Regenerates `/etc/ssmtp/ssmtp.conf` from scratch (mailhub is hardcoded to host `smtp`; `SMTP_DOMAIN` sets the rewrite domain).
7. Optionally remaps `www-data` to `WWW_UID`/`WWW_GID` (dev UID matching for bind mounts), chowns `/var/log/www`, then `exec "$@"` (default `php-fpm`).
   - The remap is skipped when `www-data` already holds the requested id, so the production case (`WWW_UID=82`) runs no `usermod` at all.
   - It uses `usermod -o` / `groupmod -o` (non-unique). This is what makes `WWW_UID=0` usable, which **rootless docker requires**: there the only container uid mapping back to the host user who owns a bind mount is 0, and root already holds it, so a plain `usermod -u 0` exits `UID '0' already exists` and `set -xe` kills the container before php starts.
   - `WWW_UID=0` additionally needs the pool to be allowed to run as root — php-fpm checks the *resolved uid*, not the user name, so remapping `www-data` to 0 is not enough on its own and fpm exits `please specify user and group other than root`. Callers must start it as `php-fpm -R`. In rootless docker that "root" is the invoking user's own unprivileged host account, not real root.

**Config contract** — `wp-config-template.php` resolves everything through `getenv()` at request time, so the file itself is static apart from the salts:

- DB: `WP_DB_NAME`, `WP_DB_USER`, `WP_DB_PASS`, `WP_DB_HOST`; path: `WP_ABSPATH`.
- Debug flags: `WP_DEBUG`, `WP_DEBUG_LOG`, `WP_DEBUG_DISPLAY`, `SCRIPT_DEBUG`, `SAVEQUERIES`, `WP_JETPACK_DEV_DEBUG`.
- Note the two prefixes are _not_ interchangeable: salts use `WORDPRESS_*`, runtime config uses `WP_*`. The entrypoint's `WORDPRESS_DEBUG*` lines are commented out and have no effect.
- FPM must actually pass these through (`clear_env`/`env[...]`) — an Apache/`SetEnv` front end can override them.

**`rename_site.php`** — reads `wp_options.home`, and if it differs from `HTTP_HOST` (web context) or `WP_HOME` (CLI), shells out to `wp search-replace`. It expects `wp` next to itself (`dirname(__FILE__)."/wp"`), but the Dockerfile installs wp-cli to `/usr/local/bin/wp`.

## Known breakage (verify before relying on these paths)

- `entrypoint.sh` invokes `${SRC_DIR}/rename.site.php`; the file is `rename_site.php`. The import-rename branch cannot work as written.
- `execute-statements-mysql.php` uses the `mysql_*` API, removed in PHP 7 — it fatals on this image. Its argument order also disagrees with the call site: the script reads `$argv[1..4]` as host, _user_, _pass_, _db_, while the entrypoint passes host, _db_, _user_, _pass_. Now that `mariadb-client` is in the image, the whole script is replaceable by piping the dump into `mysql` — which is what it was hand-rolling — but that has not been done, and the import path is still untested either way.

## Planned work

Two places, on purpose. `TODO.md` holds work that is not tied to one line —
the largest item being replacing the vendored wp-cli with the upstream
`wordpress:cli` image run as a sidecar, at which point both `/usr/local/bin/wp`
and `mariadb-client` come out of this image. Anything that *is* tied to one line
stays as a `TODO`/`FIXME` comment on that line in `Dockerfile` /
`entrypoint.sh`, where whoever edits the line will actually see it — **leave
those where they are.** `grep -rn 'TODO\|FIXME'` plus `TODO.md` is the whole
picture. Nothing in either is in flight; this section is a pointer, not a status.

## CI (`.github/workflows/`)

- `release.yml` — two jobs: `build` (matrix) → `merge`. Pushes to `ghcr.io/deas/wordpress` with tags `latest` and `8.5.$(git rev-list --count HEAD)-fpm-alpine`, always as a `linux/amd64` + `linux/arm64` manifest list. The version prefix (`8.5.`) is hardcoded in the workflow _and_ in the Makefile's `IMAGE`; bumping the PHP base means editing both plus the `Dockerfile` `FROM`.
  - Each arch builds on its own **native** runner (`ubuntu-latest`, `ubuntu-24.04-arm` — free because the repo is public), so nothing is QEMU-emulated. Adding an arch means adding a `{platform, runner}` pair to `jobs.build.strategy.matrix.include`.
  - `build` legs tag nothing. Each pushes an untagged image (`push-by-digest=true`) and uploads its digest as an artifact; `merge` collects them and does one `docker buildx imagetools create` to write the manifest list. The tags are therefore written once, atomically, from exactly the digests that run produced — no appending to an existing list, no ordering constraints. `merge` is skipped if either leg fails, so a single-arch image is never tagged.
  - **The suite gates the release, and it runs before anything is pushed.** Each leg builds with `load: true`, runs the bats suite against that exact image, and only then pushes by digest.
    - **IT IS NO LONGER THE FULL SUITE. As of 2026-08-19 the database-backed files (`40-integration`, `41-mysql`) are gated off in CI**, as a deliberate workaround for GitHub capacity problems — they pull a server image and run three containers on a docker network each, so they are where a flaky runner surfaces first. Both workflows carry the same `if: vars.RUN_INTEGRATION == '1' || inputs.run_integration`, so re-enabling needs no commit: set the repository variable, or dispatch with the box ticked. **Deleting the `if:` is what should happen once GitHub is healthy** — this is a workaround with no expiry date attached to it, which is the usual way workarounds become permanent.
    - What that costs is specific, not vague: `wp db` reaching a real server is precisely the assertion that was missing when the MySQL TLS defect shipped, so CI is now blind to that class again. `10-image`'s `--no-defaults --print-defaults` canary still runs in the fast step and still catches a *dropped* wrapper, but nothing in CI proves a connection succeeds or stays encrypted. **`make test-integration` locally before pushing is now the only place that happens.** That is why there are *two* `build-push-action` calls per leg: `load` yields a testable local image but no registry digest, push-by-digest yields a digest but nothing testable. The second call hits the same builder with every layer cached, so it costs an export and a push, not a rebuild. Since `merge` is the only step that writes a tag and it `needs: build`, `latest` cannot land on an image whose tests were red.
    - This is also the only thing that ever tests **arm64** — each leg tests on its own native runner. `cve-scan.yml` still scans amd64 only.
    - `fail-fast: false` means a green leg still pushes its digest when its sibling goes red. Those blobs are untagged and unreferenced; `merge` is skipped, so nothing points at them.
    - It was not always so. `release.yml` and `test.yml` used to trigger on the same push and run *concurrently*, so a release published regardless of the result — which is how `8.5.16-fpm-alpine` and `latest` shipped from the merge that claimed "NOT released".
  - GHA layer cache is scoped per platform (`scope=linux-amd64` / `scope=linux-arm64`); the legs never share a cache.
  - `merge` checks out with `fetch-depth: 0` because the version comes from `git rev-list --count HEAD`.
  - Not runnable under `act`: the native arm runner label, artifact v4 round-trip, and `type=gha` cache all depend on GitHub-side services. Local builds go through `make docker-build`, not `act` (`act-build` is a `false` stub).
- **CVE scanning happens in two places, and they cover different failures.**
  - **At release time**, as a step in each `release.yml` build leg: Trivy against the loaded `deas/wordpress:ci`, `exit-code: 1` on CRITICAL/HIGH with `ignore-unfixed: true`, before the push. Both arches, on native runners, and a finding stops the release. It used to be a standalone workflow that built its own amd64 copy and ran *beside* the release, so a CRITICAL finding failed that workflow while the image shipped anyway.
  - **`cve-scan.yml` is now a weekly `schedule:` (plus `workflow_dispatch`)** that scans the *published* `ghcr.io/deas/wordpress:latest` and builds nothing. It exists for the one case no commit can trigger: a CVE published against the base image after the last release, where nothing in the tree changes so no push-triggered workflow fires. It is meant to go red on its own occasionally — that is the prompt to bump the `Dockerfile` `FROM`. Caveat: `image-ref` resolves `latest` to the runner's arch, so the scheduled scan is still amd64-only; arm64 is covered at release time.
  - GitHub disables `schedule:` triggers on repositories with 60 days of no activity, so a long-quiet repo silently stops scanning.
- **The two push filters partition the tree; they do not overlap, and that is the design.** Each workflow owns one question, so read the filter to know which one runs:
  - `release.yml` — **the artefact.** Every file the Dockerfile `ADD`s (`entrypoint.sh`, `wp-config-template.php`, `execute-statements-mysql.php`, `rename_site.php`, `contentreich.ini`) plus `Dockerfile` and itself. Keep it in step with the `ADD` lines: a file that reaches the image but not this list gets tested, merged, and never published — `latest` then lags the tree indefinitely, until something unrelated touches a path that *is* listed. That is what used to happen to `wp-config-template.php`.
  - `test.yml` — **the complement.** `Makefile`, `test/**`, itself: things that change the test result but never reach the image. `Dockerfile` and `entrypoint.sh` are absent deliberately — on main, release.yml already runs this same suite against what it built, so naming them here only builds and tests amd64 twice on one commit. On a PR they are covered anyway, because `pull_request` is unfiltered.
  - `test.yml`'s `pull_request` trigger has **no path filter at all**, and release.yml never runs on a PR. So the suite is the whole PR signal and cannot be skipped by touching the "wrong" files.
  - `cve-scan.yml` — **no push filter at all any more**; see below.
