.DEFAULT_GOAL := help
HELP-DESCRIPTION-SPACING := 24
# Keep this PHP prefix in step with the Dockerfile FROM and with the build_id in
# .github/workflows/release.yml — three places, nothing enforces they agree.
IMAGE := deas/wordpress:8.5.wip-fpm-alpine

.PHONY: help docker-build act-build test test-fast

# ------- Help ----------------------- #
# Source: https://nedbatchelder.com/blog/201804/makefile_help_target.html

help:  ## Describe available tasks in Makefile
	@grep '^[a-zA-Z]' $(MAKEFILE_LIST) | \
	sort | \
	awk -F ':.*?## ' 'NF==2 {printf "\033[36m  %-$(HELP-DESCRIPTION-SPACING)s\033[0m %s\n", $$1, $$2}'

docker-build: ## Build docker image locally
# TODO: Use act?
	docker build --no-cache -t $(IMAGE) .

act-build: ## Build image with act
	false

# bats-core, with bats-support/bats-assert VENDORED under test/lib (neither is
# packaged everywhere, and a suite that only runs where someone remembered to
# install two helper libraries stops being run).
#
# The suite asserts against an image that already exists rather than building
# one, so the same command checks a local build and a published tag:
#   make test                                     the Makefile's IMAGE
#   IMAGE=ghcr.io/deas/wordpress:latest make test  whatever is live
#
# --jobs is where the time goes: the xdebug matrix and the uid remap need one
# container CREATED per case, which batching cannot help. 104s -> 30s at -j8.
# 40-integration.bats opts itself out via BATS_NO_PARALLELIZE_WITHIN_FILE.
JOBS ?= $(shell nproc 2>/dev/null || echo 4)

test: ## Run the image test suite (needs docker + bats; integration pulls mariadb)
	IMAGE=$(IMAGE) bats --jobs $(JOBS) test/

test-fast: ## Same, without the suite that needs a database
	IMAGE=$(IMAGE) SKIP_INTEGRATION=1 bats --jobs $(JOBS) test/


