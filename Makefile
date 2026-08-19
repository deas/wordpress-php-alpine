.DEFAULT_GOAL := help
HELP-DESCRIPTION-SPACING := 26
# Keep this PHP prefix in step with the Dockerfile FROM and with the build_id in
# .github/workflows/release.yml — three places, nothing enforces they agree.
# ?= and NOT :=. A Makefile variable assigned with := beats the environment, so
# with `:=` here the documented `IMAGE=ghcr.io/deas/wordpress:latest make test`
# silently tested the LOCAL image instead — the run goes green and the tag you
# meant to check was never pulled, let alone asserted against.
IMAGE ?= deas/wordpress:8.5.wip-fpm-alpine

.PHONY: help build docker-build act-build \
        test test-fast test-serial \
        test-image test-xdebug test-entrypoint test-integration test-mysql \
        test-list test-env test-clean retest \
        shell shell-ep

# ------- Help ----------------------- #
# Source: https://nedbatchelder.com/blog/201804/makefile_help_target.html

help:  ## Describe available tasks in Makefile
	@grep '^[a-zA-Z]' $(MAKEFILE_LIST) | \
	sort | \
	awk -F ':.*?## ' 'NF==2 {printf "\033[36m  %-$(HELP-DESCRIPTION-SPACING)s\033[0m %s\n", $$1, $$2}'

# ------- Build ---------------------- #

build: ## Build image locally, CACHED — the edit/test loop
	docker build -t $(IMAGE) .

docker-build: ## Build image locally, --no-cache (what release does)
	docker build --no-cache -t $(IMAGE) .

act-build: ## Build image with act
	false

# ------- Test ----------------------- #
#
# bats-core, with bats-support/bats-assert VENDORED under test/lib (neither is
# packaged everywhere, and a suite that only runs where someone remembered to
# install two helper libraries stops being run).
#
# The suite asserts against an image that ALREADY EXISTS and never builds one,
# so the same targets check a local build and a published tag:
#
#   make test                                      the IMAGE above
#   IMAGE=ghcr.io/deas/wordpress:latest make test   whatever is live
#
# Three knobs, all usable on any test target:
#
#   JOBS=1                     serial. Parallel interleaves output; when a test
#                              misbehaves this is the first thing to reach for.
#   FILTER='xdebug|salt'       bats --filter, a regex over TEST NAMES.
#   BATS_FLAGS=--show-output-of-passing-tests
#                              anything else to hand bats. --print-output-on-failure
#                              and --verbose-run are the other useful ones.
#
#   make test-xdebug JOBS=1 FILTER='does NOT load' BATS_FLAGS=--verbose-run
#
# --jobs is where the time goes: the xdebug matrix and the uid remap need one
# container CREATED per case, which batching cannot help. 105s -> 33s at -j8.
# 40-integration.bats opts itself out via BATS_NO_PARALLELIZE_WITHIN_FILE.
BATS       ?= bats
JOBS       ?= $(shell nproc 2>/dev/null || echo 4)
FILTER     ?=
BATS_FLAGS ?=
TEST_DIR   := test

BATS_RUN = IMAGE=$(IMAGE) $(BATS) --jobs $(JOBS) \
           $(if $(FILTER),--filter '$(FILTER)') $(BATS_FLAGS)

test: ## Run everything (needs docker + bats; integration pulls mariadb)
	$(BATS_RUN) $(TEST_DIR)

test-fast: ## Everything except the suite that needs a database
	SKIP_INTEGRATION=1 $(BATS_RUN) $(TEST_DIR)

test-serial: ## Everything, one at a time — readable output when debugging
	$(MAKE) test JOBS=1

test-image: ## Only 10-image: extensions, gd/imagick/ICU, build hygiene
	$(BATS_RUN) $(TEST_DIR)/10-image.bats

test-xdebug: ## Only 20-xdebug: the enable/disable truth table
	$(BATS_RUN) $(TEST_DIR)/20-xdebug.bats

test-entrypoint: ## Only 30-entrypoint: uid remap, ssmtp, the salt contract
	$(BATS_RUN) $(TEST_DIR)/30-entrypoint.bats

# CI DOES NOT RUN THESE any more (2026-08-19, GitHub capacity workaround — see
# the gated step in .github/workflows/test.yml). Until that is reverted, running
# them locally before you push is the only place they run at all.
test-integration: ## The database-backed suites: MariaDB + MySQL. NOT run by CI
	$(BATS_RUN) $(TEST_DIR)/40-integration.bats $(TEST_DIR)/41-mysql.bats

test-mysql: ## Only 41-mysql: wp db against MySQL, which is what live runs
	$(BATS_RUN) $(TEST_DIR)/41-mysql.bats

retest: build test-fast ## Cached rebuild, then the fast suites — the tight loop

test-list: ## List every test name without running anything
	@grep -h '^@test' $(TEST_DIR)/*.bats \
	  | sed -e 's/^@test "//' -e 's/" {$$//' \
	  | nl -ba -w3 -s'  '
	@printf '\n%s tests in %s files\n' \
	  "$$(grep -h '^@test' $(TEST_DIR)/*.bats | wc -l)" \
	  "$$(ls $(TEST_DIR)/*.bats | wc -l)"

test-env: ## Check the tools and image the suite needs before blaming the tests
	@printf 'docker    '; command -v docker  >/dev/null && docker --version || echo 'MISSING'
	@printf 'bats      '; command -v $(BATS) >/dev/null && $(BATS) --version || echo 'MISSING — install bats-core'
	@printf 'parallel  '; command -v parallel >/dev/null && echo 'present (bats --jobs works)' \
	  || echo 'MISSING — bats --jobs needs it; use JOBS=1'
	@printf 'helpers   '; test -f $(TEST_DIR)/lib/bats-assert/load.bash \
	  && echo 'vendored bats-assert/bats-support present' || echo 'MISSING — test/lib is incomplete'
	@printf 'image     '; docker image inspect $(IMAGE) >/dev/null 2>&1 \
	  && echo '$(IMAGE)' || echo '$(IMAGE) NOT BUILT — run: make build'
	@printf 'leftovers '; test -z "$$(docker ps -aq --filter name=wp-image-test)" \
	  && echo 'none' || echo 'integration containers still around — run: make test-clean'

# 40-integration cleans up after itself via teardown_file, but a Ctrl-C mid-run
# leaves the database container, volume and network behind — and the next run
# then reuses a volume that already has WordPress in it, so "first boot
# downloads WordPress" fails for a reason that has nothing to do with the image.
# Matches on the shared wp-image-test prefix rather than three literal names.
test-clean: ## Remove containers/volumes/networks left by an interrupted run
	@ids=$$(docker ps -aq --filter name=wp-image-test); \
	  [ -n "$$ids" ] && docker rm -f $$ids || echo 'no containers'
	@vols=$$(docker volume ls -q --filter name=wp-image-test); \
	  [ -n "$$vols" ] && docker volume rm -f $$vols || echo 'no volumes'
	@nets=$$(docker network ls -q --filter name=wp-image-test); \
	  [ -n "$$nets" ] && docker network rm $$nets || echo 'no networks'

# ------- Poking at the image -------- #
#
# The two shells mirror the sh_probe/ep_probe split the tests use, and the
# difference matters: bypassing the entrypoint shows you what the BUILD
# produced, running through it shows you what a real container looks like —
# uid remap applied, ssmtp.conf written, xdebug ini installed or not.
#
# XENV passes extra docker flags, which is how you reproduce a failing case:
#   make shell-ep XENV='-e PHP_XDEBUG_ENABLED=1 -e XDEBUG_MODE=develop'
#   make shell-ep XENV='-e WWW_UID=0'
XENV ?=

shell: ## Shell in the image, entrypoint BYPASSED (inspect what the build made)
	docker run --rm -it --entrypoint sh $(IMAGE)

shell-ep: ## Shell in the image, entrypoint RUN FIRST (see what it actually does)
	docker run --rm -it -e WP_DB_PASS=probe $(XENV) $(IMAGE) sh
