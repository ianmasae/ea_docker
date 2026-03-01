# =============================================================================
# MT5 Docker — Makefile
# =============================================================================
#
# Quick start:
#   make backtest EA=FibonacciGoldenZone
#   make backtest EA=FibonacciGoldenZone SYMBOL="Volatility 10 (1s) Index" PERIOD=H1
#   make backtest-json EA=FibonacciGoldenZone > results.json
#   make backtest-csv EA=FibonacciGoldenZone > results.csv
#
# =============================================================================

CONTAINER := mt5-headless
BACKTEST_CMD := /scripts/backtest.sh

# Backtest parameters (all optional except EA)
EA ?=
SYMBOL ?= Volatility 10 (1s) Index
PERIOD ?= H1
FROM ?=
TO ?=
DEPOSIT ?= 10000
MODEL ?= 0

# Build the backtest arguments
BACKTEST_ARGS := --ea "$(EA)" --symbol "$(SYMBOL)" --period "$(PERIOD)" --deposit "$(DEPOSIT)" --model "$(MODEL)"
ifdef FROM
  BACKTEST_ARGS += --from "$(FROM)"
endif
ifdef TO
  BACKTEST_ARGS += --to "$(TO)"
endif

API_PORT ?= 8000
API_URL := http://localhost:$(API_PORT)

.PHONY: help backtest backtest-json backtest-csv list-eas build up down restart logs setup-bridge api-health api-account api-positions api-symbols

help: ## Show this help
	@echo ""
	@echo "MT5 Docker Commands"
	@echo "==================="
	@echo ""
	@echo "Backtesting:"
	@echo "  make backtest EA=<name>              Run backtest, show results in terminal"
	@echo "  make backtest-json EA=<name>         Run backtest, output JSON (pipe to file)"
	@echo "  make backtest-csv EA=<name>          Run backtest, output CSV (pipe to file)"
	@echo "  make list-eas                        List available Expert Advisors"
	@echo ""
	@echo "Options (all optional):"
	@echo "  EA=FibonacciGoldenZone               EA name (required, no extension)"
	@echo "  SYMBOL=\"Volatility 10 (1s) Index\"    Trading symbol"
	@echo "  PERIOD=H1                            Timeframe: M1,M5,M15,M30,H1,H4,D1,W1,MN"
	@echo "  FROM=2025.12.01                      Start date"
	@echo "  TO=2026.02.28                        End date"
	@echo "  DEPOSIT=10000                        Initial deposit"
	@echo "  MODEL=0                              0=Every tick, 1=1min OHLC, 2=Open price"
	@echo ""
	@echo "Trading API (first-time setup: make setup-bridge):"
	@echo "  make setup-bridge                    Start BridgeService (one-time)"
	@echo "  make api-health                      Check API + EA connection status"
	@echo "  make api-account                     Show account info"
	@echo "  make api-positions                   List open positions"
	@echo "  make api-symbols                     List available symbols"
	@echo ""
	@echo "Docker:"
	@echo "  make build                           Build the Docker image"
	@echo "  make up                              Start the container"
	@echo "  make down                            Stop the container"
	@echo "  make restart                         Restart the container"
	@echo "  make logs                            Tail container logs"
	@echo ""
	@echo "Examples:"
	@echo "  make backtest EA=FibonacciGoldenZone"
	@echo "  make backtest EA=FibonacciGoldenZone SYMBOL=\"Volatility 75 Index\" PERIOD=M15"
	@echo "  make backtest-json EA=FibonacciGoldenZone FROM=2025.12.01 > results.json"
	@echo ""

backtest: _check-ea ## Run backtest and show results in terminal
	docker exec $(CONTAINER) $(BACKTEST_CMD) $(BACKTEST_ARGS) --format text

backtest-json: _check-ea ## Run backtest and output JSON
	docker exec $(CONTAINER) $(BACKTEST_CMD) $(BACKTEST_ARGS) --format json

backtest-csv: _check-ea ## Run backtest and output CSV
	docker exec $(CONTAINER) $(BACKTEST_CMD) $(BACKTEST_ARGS) --format csv

list-eas: ## List available Expert Advisors
	@echo "Available Expert Advisors:"
	@docker exec $(CONTAINER) bash -c 'MT5_DIR=$$(cat $${WINEPREFIX}/.mt5-path 2>/dev/null); ls -1 "$${MT5_DIR}/MQL5/Experts/"*.mq5 "$${MT5_DIR}/MQL5/Experts/"*.ex5 2>/dev/null | xargs -I{} basename {} | sort -u || echo "  (none found)"'
	@echo ""
	@echo "Source files mounted from host:"
	@ls -1 ..//*.mq5 ../*.ex5 2>/dev/null | xargs -I{} basename {} | sort -u || echo "  (none found)"

build: ## Build the Docker image
	docker compose build

up: ## Start the container
	docker compose up -d

down: ## Stop the container
	docker compose down

restart: ## Restart the container
	docker compose restart mt5

logs: ## Tail container logs
	docker compose logs -f mt5

setup-bridge: ## Start the BridgeService (one-time setup)
	@docker exec $(CONTAINER) /scripts/start_bridge_service.sh 30

api-health: ## Check API + EA connection status
	@curl -s $(API_URL)/health | python3 -m json.tool 2>/dev/null || echo "API not reachable at $(API_URL)"

api-account: ## Show account info
	@curl -s $(API_URL)/account | python3 -m json.tool 2>/dev/null || echo "API not reachable at $(API_URL)"

api-positions: ## List open positions
	@curl -s $(API_URL)/positions | python3 -m json.tool 2>/dev/null || echo "API not reachable at $(API_URL)"

api-symbols: ## List available symbols
	@curl -s $(API_URL)/symbols | python3 -m json.tool 2>/dev/null || echo "API not reachable at $(API_URL)"

# Internal targets
_check-ea:
ifndef EA
	$(error EA is required. Usage: make backtest EA=FibonacciGoldenZone)
endif
