# TODO

Outstanding work that is not tied to one line of one file.

**Inline `TODO`/`FIXME` markers in `Dockerfile` and `entrypoint.sh` are
deliberate and stay there — do not sweep them into this file.** A note about why
`--with-freetype` is in the gd configure line belongs next to that line, where
whoever edits it will see it; pulled out to a list it is a fact nobody reads at
the moment it matters. `grep -rn 'TODO\|FIXME'` is the complete view.

Descriptive documentation stays where it is: `AGENTS.md` explains how the image
*works* and what is currently *broken* (its "Known breakage" section), this file
is only what we intend to *do*.

---

## Replace wp-cli with the upstream `wordpress:cli` image

**The intent: use `wordpress:cli` AS IS, as a sidecar against the shared
`/usr/share/wordpress` volume, and stop carrying wp-cli here at all.** Not
vendoring its phar into this image — that was considered and rejected; it keeps
the maintenance we are trying to shed. Until the move happens, the curled phar
and `mariadb-client` stay exactly as they are, so `wp db` works today.

What lands when it does: **`/usr/local/bin/wp` and the `mariadb-client` package
both come back out of this image** (−39 MB, and one less thing to keep current).
That is the prize.

Measured against `wordpress:cli` on 2026-08-17 — WP-CLI 2.12.0, **PHP 8.3.33**,
Alpine 3.24.1, 284 MB, runs as `www-data` uid 82, and it already ships
`mariadb-client` itself (independent confirmation of what `wp db` needs).

Blockers, each needing an answer before starting:

- [ ] **PHP version skew, the big one.** Upstream `cli` is PHP **8.3.33**; this
      image is 8.5. A sidecar means one WordPress install executed by two
      different PHP minors — `wp cli info`, Site Health, and any plugin code
      reached through `wp` would run on a PHP the site itself never uses. Check
      whether a `cli-php8.5` tag exists by then; there was none at the time of
      writing, so this is not merely a pinning question.
- [ ] `test/40-integration.bats` runs `wp` **inside** the image under test
      (`it_run wp --allow-root core install`). Its whole shape changes — it has
      to orchestrate a second container against the shared volume instead.
- [ ] `rename_site.php` shells out to `dirname(__FILE__)."/wp"`. Already broken
      (see AGENTS.md "Known breakage"), but a sidecar makes "wp is not in this
      container" permanent, so that path needs rewriting rather than a one-line
      fix.
- [ ] The `WWW_UID`/`WWW_GID` remap does not reach a sidecar. Dev bind-mount
      setups would need it applied twice, and the rootless `WWW_UID=0` case has
      no equivalent there at all — see the `usermod -o` notes in AGENTS.md for
      why that one is not negotiable.
- [ ] It is a change to the **consuming compose files** (contentreich-wordpress),
      not only to this repo, so it cannot land here alone.

## Build

- [ ] Try a [Chainguard Image](https://www.chainguard.dev/chainguard-images)
      (Wolfi) as the base. *(was `README.md`)*
- [ ] Introduce `devenv`. *(was `README.md`)*

## Tests and CI

- [ ] **`make act-build` is a `false` stub.** Leverage `act` for local CI runs,
      or remove the target. Note what makes it hard, per AGENTS.md: the native
      arm runner label, the artifact v4 round-trip, and `type=gha` cache all
      depend on GitHub-side services. *(was `README.md`, under the Wolfi item)*

## Docs

- [ ] **Write the README.** "Getting Started", "Prerequisites" and "Usage" are
      still literal `TODO` placeholders from the template it was started from.
      Those markers are left in place deliberately — they are section stubs, and
      removing them would leave a README that looks finished and is not.
