ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export PATH := $(ROOT)/bin:$(PATH)

SPUR_GW := $(ROOT)/bin/spur-gw
COMPOSE := docker compose -f $(ROOT)/docker-compose.yml --project-directory $(ROOT)

.PHONY: help env build rebuild up up-mock down status logs test smoke-mock shell

.DEFAULT_GOAL := help

help: ## Show this help
	@printf '%s\n' \
		'spur-gateway — common targets' \
		'' \
		'Usage: make <target>' \
		''
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  %-18s %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing; set SPUR_SUB_URL
	@if [ -f '$(ROOT)/.env' ]; then \
		echo '.env already exists'; \
	elif [ -f '$(ROOT)/.env.example' ]; then \
		cp '$(ROOT)/.env.example' '$(ROOT)/.env'; \
		echo 'created .env — fill in SPUR_SUB_URL'; \
	else \
		echo '.env.example not present yet; create .env with SPUR_SUB_URL later'; \
	fi

build: ## Build the Docker image
	$(COMPOSE) build

rebuild: ## Rebuild the image without cache
	$(COMPOSE) build --no-cache

up: build ## Live gateway (SPUR_MOCK=0): build + spur-gw up
	SPUR_MOCK=0 $(SPUR_GW) up

up-mock: build ## Mock gateway (SPUR_MOCK=1): build + spur-gw up
	SPUR_MOCK=1 $(SPUR_GW) up

down: ## Stop the compose stack
	$(SPUR_GW) down

status: ## Compose and health status
	$(SPUR_GW) status

logs: ## Tail gateway container logs
	$(COMPOSE) logs gateway --tail 100

test: ## Run the test suite
	bash '$(ROOT)/tests/run.sh'

smoke-mock: ## Smoke: curl through the mock proxy
	spur curl -sI https://example.com

shell: ## Hint: export PATH for this session
	@echo 'export PATH="$(ROOT)/bin:$$PATH"'
