.PHONY: help build _building clean _cleaning test _testing coverage _prepare-cov 

# --- Colors ---

GREEN := \033[0;32m
CYAN := \033[0;36m
YELLOW := \033[1;33m
RED := \033[0;31m
RESET := \033[0m

# --- Help ---

## Display this help menu with descriptions of each command
help:
	@echo "$(YELLOW)NetSkein Makefile Commands:$(RESET)"
	@awk '/^[a-zA-Z\-_0-9\s]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = substr($$1, 0, index($$1, ":")-1); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			printf "  $(GREEN)%-20s$(RESET) %s\n", helpCommand, helpMessage; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)
	@echo ""

# --- Build ---

## Build the Swift package using Debug configuration
build:
	@clear
	@$(MAKE) _building

_building:
	@echo "$(CYAN)>>> Building Swift Package in Debug Configuration...$(RESET)"
	@swift build

# --- Clean ---

## Clean the Swift package build artifacts (Derived Data)
clean:
	@clear
	@$(MAKE) _cleaning

_cleaning:
	@echo "$(YELLOW)>>> Cleaning Swift Package Derived Data...$(RESET)"
	@swift package clean
	@echo "$(GREEN)>>> Success Cleaning Swift Package Derived Data...$(RESET)"

# --- Test ---

## Run all Tests in Release configuration
test: 
	@clear
	@$(MAKE) _testing

_testing:
	@echo "$(CYAN)>>> Running All Tests...$(RESET)"
	@swift test

_testing-cov:
	@echo "$(CYAN)>>> Running All Tests with Code Coverage...$(RESET)"
	@swift test --enable-code-coverage

# --- Coverage ---

COV_BINARY   := .build/out/Products/Debug/NetSkeinTests.xctest/Contents/MacOS/NetSkeinTests
COV_PROFILE  := .build/out/Products/Debug/codecov/default.profdata
COV_OUT_DIR  := .build/coverage-report

## Generate HTML code coverage report
coverage: 
	@clear
	@$(MAKE) _prepare-cov
	@$(MAKE) _testing-cov
	@echo "$(CYAN)>>> Generating Coverage Report...$(RESET)"
	@xcrun llvm-cov show \
	  $(COV_BINARY) \
	  -instr-profile=$(COV_PROFILE) \
	  -format=html -output-dir=$(COV_OUT_DIR) \
	  Sources
	@echo "$(GREEN)>>> Report generated at: $(COV_OUT_DIR)/index.html$(RESET)"

## Generate terminal-based summary code coverage report
cov:
	@$(MAKE) _testing-cov
	@./Scripts/check-coverage.sh

_prepare-cov:
	@mkdir -p $(COV_OUT_DIR)
