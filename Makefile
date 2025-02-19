# Configuration
VENV := venv
PYTHON_VERSION := $(shell python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
PYTHON := python$(PYTHON_VERSION)
PIP := $(VENV)/bin/pip
USER := $(shell whoami)

# SSH tunnel configuration
SSH_USER := ubuntu
SSH_HOST := 168.119.194.135
SSH_PORT := 2203
DB_CONTAINER_IP := 172.17.0.2
LOCAL_PORT := 5433
REMOTE_PORT := 5432
SSH_KEY_PATH := $(HOME)/.ssh/mix-maptiler-ssh

# Main build target
.PHONY: all
all: clean install-deps create-env setup-venv download-data build-nominatim

# Clean everything
.PHONY: clean
clean:
	@echo "🧹 Cleaning up..."
	rm -rf $(VENV)
	rm -rf dist/*
	rm -rf build/*
	rm -rf data/*
	rm -f data/flatnode.file
	rm -f data/import-style.lua
	rm -f data/no_water.lua
	rm -f data/*.osm.pbf
	rm -rf data/module*
	rm -rf data/tiger*
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Create environment configuration
.PHONY: create-env
create-env:
	@echo "📝 Creating environment configuration..."
	@mkdir -p data

# Install system dependencies
.PHONY: install-deps
install-deps:
	@echo "📦 Installing system dependencies..."
	@echo "🐍 Detected Python version: $(PYTHON_VERSION)"
	sudo apt-get update
	sudo apt-get install -y \
		build-essential cmake g++ \
		libboost-dev libboost-system-dev \
		libboost-filesystem-dev \
		libexpat1-dev zlib1g-dev \
		libbz2-dev libpq-dev libproj-dev \
		pkg-config libicu-dev \
		postgresql-server-dev-all \
		python3-dev python3-venv \
		acl git wget osm2pgsql

# Setup Python virtual environment
.PHONY: setup-venv
setup-venv:
	@echo "🐍 Setting up Python virtual environment..."
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install \
		build wheel hatchling \
		psycopg2-binary PyICU \
		python-dotenv pytidylib \
		Jinja2 datrie pytest \
		pytest-cov behave \
		behave-html-formatter \
		flake8 mypy types-psycopg2 \
		types-PyYAML mkdocs \
		mkdocs-material watchdog \
		uvicorn fastapi falcon \
		falcon-multipart

# Download required data files
.PHONY: download-data
download-data:
	@echo "📥 Downloading required data files..."
	mkdir -p packaging/nominatim-db/data
	wget -O packaging/nominatim-db/data/country_osm_grid.sql.gz \
		https://nominatim.org/data/country_grid.sql.gz
	wget -O packaging/nominatim-db/data/words.sql \
		https://raw.githubusercontent.com/osm-search/Nominatim/master/data/words.sql

# Build Nominatim
.PHONY: build-nominatim
build-nominatim:
	@echo "🏗️ Building Nominatim..."
	mkdir -p build/nominatim_db-5.0.0
	mkdir -p build/nominatim_api-5.0.0
	cp COPYING build/nominatim_db-5.0.0/
	cp COPYING build/nominatim_api-5.0.0/
	cd packaging/nominatim-db && \
	PYTHONPATH=../../ \
	PYTHONWARNINGS=ignore::DeprecationWarning \
	../../$(VENV)/bin/python -m build \
		--no-isolation \
		--wheel \
		--outdir ../../dist/
	cd packaging/nominatim-api && \
	PYTHONPATH=../../ \
	../../$(VENV)/bin/python -m build \
		--no-isolation \
		--wheel \
		--outdir ../../dist/
	$(PIP) install --force-reinstall dist/nominatim_*.whl

# Import test data (Iceland - admin boundaries and places only)
.PHONY: import-test-data
import-test-data:
	@echo "🗺️ Downloading and importing wales test data..."
	mkdir -p data
	cp settings/wales-latest.osm.pbf data/
	$(VENV)/bin/nominatim import \
		--osm-file data/wales-latest.osm.pbf \
		--project-dir data

# Development mode with live reload
.PHONY: dev
dev: build-nominatim
	@echo "🔄 Starting development server with auto-reload..."
	$(PIP) install -e packaging/nominatim-api
	$(PIP) install -e packaging/nominatim-db
	$(PIP) install uvicorn watchfiles
	PYTHONPATH=src $(VENV)/bin/uvicorn \
		"nominatim_api.server.starlette.server:run_wsgi" \
		--host 127.0.0.1 \
		--port 8088 \
		--reload \
		--reload-dir src \
		--log-level debug \
		--factory

# Start server
.PHONY: serve
serve:
	@echo "🚀 Starting Nominatim server..."
	$(VENV)/bin/nominatim serve --project-dir data

# Show system info
.PHONY: info
info:
	@echo "System Information:"
	@echo "  Python Version: $(PYTHON_VERSION)"
	@echo "  Operating System: $(shell lsb_release -ds)"
	-@psql -d nominatim -c "\dx" 2>/dev/null

# Open SSH tunnel
.PHONY: tunnel-open
tunnel-open:
	@echo "🔗 Opening SSH tunnel..."
	@echo "⌨️  Please enter your SSH key password when prompted..."
	@mkdir -p logs
	@ssh -p $(SSH_PORT) -i $(SSH_KEY_PATH) -N -L $(LOCAL_PORT):$(DB_CONTAINER_IP):$(REMOTE_PORT) $(SSH_USER)@$(SSH_HOST) > logs/tunnel.log 2>&1 &
	@sleep 5
	@if netstat -tln | grep -q ":$(LOCAL_PORT)"; then \
		echo "✅ Tunnel started successfully. Local port $(LOCAL_PORT) -> $(DB_CONTAINER_IP):$(REMOTE_PORT)"; \
	else \
		echo "❌ Failed to establish tunnel. Check logs/tunnel.log for details."; \
		exit 1; \
	fi

# Close SSH tunnel
.PHONY: tunnel-close
tunnel-close:
	@echo "🔌 Closing SSH tunnel..."
	-pkill -f "ssh.*$(LOCAL_PORT):$(DB_CONTAINER_IP):$(REMOTE_PORT)" || true
	@echo "Tunnel closed (if it was running)."

# Check tunnel status
.PHONY: tunnel-status
tunnel-status:
	@echo "📊 Checking tunnel status..."
	@if pgrep -f "ssh.*$(LOCAL_PORT):$(DB_CONTAINER_IP):$(REMOTE_PORT)"; then \
		echo "Tunnel is active"; \
		echo "Process: $$(ps aux | grep "ssh.*$(LOCAL_PORT):$(DB_CONTAINER_IP):$(REMOTE_PORT)" | grep -v grep)"; \
	else \
		echo "No active tunnel"; \
	fi

# Help target
.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make          - Clean install and build everything"
	@echo "  make clean    - Remove all built and temporary files"
	@echo "  make create-env - Create environment configuration files"
	@echo "  make serve    - Start Nominatim server"
	@echo "  make dev      - Start development server with live reload"
	@echo "  make import-test-data - Import Iceland test data"
	@echo "  make info     - Show system information"
	@echo "  make tunnel-open  - Open SSH tunnel to database"
	@echo "  make tunnel-close - Close SSH tunnel to database"
	@echo "  make tunnel-status - Check SSH tunnel status"
	@echo "  make help     - Show this help message"
	@echo "  make stop     - Stop the running Nominatim server"

# Default target
.DEFAULT_GOAL := all