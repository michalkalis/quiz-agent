# quiz-pack-api local dev (issue #33 Task 1.1).
# This directory will be renamed to apps/quiz-pack-api/ in Task 1.2.
#
# Conventions:
# - All targets assume cwd = apps/question-generator/.
# - Postgres + Redis run in docker-compose; uvicorn + arq run on the host.
# - ARQ worker target is wired in Task 1.10 (no WorkerSettings exist yet).

PORT ?= 8003
COMPOSE := docker compose

APPLE_ROOT_CERT := app/storekit/certs/AppleRootCA-G3.cer

.PHONY: help dev dev-db dev-api dev-worker dev-down dev-reset dev-logs dev-psql dev-redis-cli fetch-apple-root

help:
	@echo "Targets:"
	@echo "  make dev              - boot postgres + redis + uvicorn (ARQ worker once 1.10 lands)"
	@echo "  make dev-db           - boot postgres + redis only"
	@echo "  make dev-api          - run uvicorn on :$(PORT) (assumes dev-db already up)"
	@echo "  make dev-worker       - run ARQ worker (stub until Task 1.10)"
	@echo "  make dev-down         - stop containers, keep volumes"
	@echo "  make dev-reset        - stop containers AND drop volumes (DESTROYS data)"
	@echo "  make dev-logs         - tail compose logs"
	@echo "  make dev-psql         - psql into local quiz_pack DB"
	@echo "  make dev-redis-cli    - redis-cli into local Redis"
	@echo "  make fetch-apple-root - download AppleRootCA-G3.cer for StoreKit JWS verify (Task 1.8)"

fetch-apple-root:
	@if [ -f $(APPLE_ROOT_CERT) ]; then \
		echo "==> $(APPLE_ROOT_CERT) already present, skipping"; \
	else \
		echo "==> downloading AppleRootCA-G3.cer"; \
		curl -fsSL -o $(APPLE_ROOT_CERT) \
			https://www.apple.com/certificateauthority/AppleRootCA-G3.cer; \
		shasum -a 256 $(APPLE_ROOT_CERT); \
	fi

dev: dev-db
	@echo "==> Starting uvicorn on :$(PORT)"
	@echo "    (ARQ worker not yet wired — see Task 1.10)"
	uvicorn app.main:app --reload --host 0.0.0.0 --port $(PORT)

dev-db:
	$(COMPOSE) up -d --wait postgres redis
	@echo "==> postgres + redis ready"

dev-api:
	uvicorn app.main:app --reload --host 0.0.0.0 --port $(PORT)

dev-worker:
	@echo "ARQ worker is wired in Task 1.10 (app.worker.WorkerSettings does not exist yet)."
	@echo "When ready, this target will run: arq app.worker.WorkerSettings"
	@exit 1

dev-down:
	$(COMPOSE) down

dev-reset:
	$(COMPOSE) down -v

dev-logs:
	$(COMPOSE) logs -f --tail=100

dev-psql:
	$(COMPOSE) exec postgres psql -U quiz -d quiz_pack

dev-redis-cli:
	$(COMPOSE) exec redis redis-cli
