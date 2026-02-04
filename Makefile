SHELL := /bin/bash

SWIFT ?= swift
SWIFT_FORMAT ?= swiftformat
SWIFT_LINT ?= swiftlint

.PHONY: help format lint test build

help:
	@echo "Targets:"
	@echo "  format  Format code if swiftformat is installed"
	@echo "  lint    Lint code if swiftlint is installed"
	@echo "  test    Run tests"
	@echo "  build   Build the package"

format:
	@if command -v "$(SWIFT_FORMAT)" >/dev/null 2>&1; then \
		(cd Sources/Hive && "$(SWIFT_FORMAT)" .); \
	else \
		echo "swiftformat not installed; skipping format"; \
	fi

lint:
	@if command -v "$(SWIFT_LINT)" >/dev/null 2>&1; then \
		(cd Sources/Hive && "$(SWIFT_LINT)" --strict); \
	else \
		echo "swiftlint not installed; skipping lint"; \
	fi

test:
	"$(SWIFT)" test

build:
	"$(SWIFT)" build
