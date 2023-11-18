.DEFAULT_GOAL := help
HELP-DESCRIPTION-SPACING := 24
IMAGE := deas/wordpress:8.1.wip-fpm-alpine

.PHONY: help docker-build act-build

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


