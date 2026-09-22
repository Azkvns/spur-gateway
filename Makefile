ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: help env

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
