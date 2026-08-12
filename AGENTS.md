# AGENTS.md

## What this is

A single container image (`ghcr.io/deas/wordpress`, `php:8.5-fpm-alpine` base) that runs WordPress under PHP-FPM. There is no application code here — WordPress itself is downloaded at container start. The repo is the _execution environment_: PHP extensions, `wp-cli`, ssmtp mail, xdebug, and a boot script that provisions/repairs a WordPress install from environment variables.

## Commands

```sh
make                 # help (default goal), lists targets
make docker-build    # docker build --no-cache -t deas/wordpress:8.5.wip-fpm-alpine .
```

There is no test suite — `.github/workflows/test.yml` only echoes `make test`, and `make act-build` is a stub that runs `false`. Verification means building the image and running it against a MySQL container.

## Architecture

**Build (`Dockerfile`)** — installs gd (jpeg/freetype/webp/avif), zip, mysqli, exif, intl, imagick, xdebug, and `wp` (wp-cli phar) into `/usr/local/bin`. `contentreich.ini` (dropped into `conf.d`) points `mysqli.default_socket` at `/var/run/mysqld/mysqld.sock` so a socket mount works.

Four things about this layer are load-bearing and easy to undo by accident:

- **`opcache` is NOT in the ext-install list.** As of PHP 8.5 the official image compiles it in statically, so `docker-php-ext-install opcache` builds no module and fails the layer with `cp: can't stat 'modules/*'`. It is still loaded — the untouched base already reports `Zend OPcache` in `php -m`. Adding it back breaks the build outright.
- **No `edge/community` repository.** It used to be added "as a quick hack to get usermod/groupmod from shadow", and it was a standing hazard: with edge in the list, any apk resolution may pull an edge package onto a stable base. `shadow` is in `v3.24/community`, which the base already enables.
- **Build deps are a deleted virtual package.** The `-dev` headers used to be installed as `.persistent-deps` and never removed, so they shipped to production — weight, plus CVE surface that `cve-scan.yml` then reported against.
- **`exif` / `intl` / `imagick` answer WordPress's own Site Health**, which listed all three as missing optional modules. `imagick` is the one taken on a calculated risk: Alpine 3.24 ships ImageMagick 7.1.2-27 marked *(Beta)*, and installing it **changes which image editor WordPress picks** — on contentreich it moved from GD to `EWWWIO_Imagick_Editor`. Back it out by dropping the module plus the `imagemagick`/`imagemagick-dev` packages.

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
5. Rewrites the 8 auth keys/salts in `wp-config.php` via `sed`, taking `WORDPRESS_<KEY>` env vars (e.g. `WORDPRESS_AUTH_KEY`) or generating random values.
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
- `execute-statements-mysql.php` uses the `mysql_*` API, removed in PHP 7 — it fatals on this image. Its argument order also disagrees with the call site: the script reads `$argv[1..4]` as host, _user_, _pass_, _db_, while the entrypoint passes host, _db_, _user_, _pass_.

## CI (`.github/workflows/`)

- `release.yml` — two jobs: `build` (matrix) → `merge`. Pushes to `ghcr.io/deas/wordpress` with tags `latest` and `8.5.$(git rev-list --count HEAD)-fpm-alpine`, always as a `linux/amd64` + `linux/arm64` manifest list. The version prefix (`8.5.`) is hardcoded in the workflow _and_ in the Makefile's `IMAGE`; bumping the PHP base means editing both plus the `Dockerfile` `FROM`.
  - Each arch builds on its own **native** runner (`ubuntu-latest`, `ubuntu-24.04-arm` — free because the repo is public), so nothing is QEMU-emulated. Adding an arch means adding a `{platform, runner}` pair to `jobs.build.strategy.matrix.include`.
  - `build` legs tag nothing. Each pushes an untagged image (`push-by-digest=true`) and uploads its digest as an artifact; `merge` collects them and does one `docker buildx imagetools create` to write the manifest list. The tags are therefore written once, atomically, from exactly the digests that run produced — no appending to an existing list, no ordering constraints. `merge` is skipped if either leg fails, so a single-arch image is never tagged.
  - GHA layer cache is scoped per platform (`scope=linux-amd64` / `scope=linux-arm64`); the legs never share a cache.
  - `merge` checks out with `fetch-depth: 0` because the version comes from `git rev-list --count HEAD`.
  - Not runnable under `act`: the native arm runner label, artifact v4 round-trip, and `type=gha` cache all depend on GitHub-side services. Local builds go through `make docker-build`, not `act` (`act-build` is a `false` stub).
- `cve-scan.yml` — Trivy on the freshly built image, `exit-code: 1` on CRITICAL/HIGH with `ignore-unfixed: true`. Builds the runner's native amd64 only — the arm64 image is never scanned. Base-image bumps are usually driven by this.
- All three workflows filter on `paths: Dockerfile, entrypoint.sh, .github/workflows/release.yml` (note: `release.yml`, even inside `test.yml` and `cve-scan.yml`). Changes to the PHP scripts, `contentreich.ini`, or `wp-config-template.php` ship in the image but trigger no CI run.
