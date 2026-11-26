.PHONY: test lint manifest manifest-sign manifest-verify release

test:
	@bash tests/test_runner.sh

lint:
	@echo "Checking syntax..."
	@bash -n bin/muster
	@bash -n bin/muster-mcp
	@for f in lib/core/*.sh lib/commands/*.sh lib/tui/*.sh lib/skills/*.sh; do \
		bash -n "$$f" || exit 1; \
	done
	@echo "All files pass syntax check"
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running ShellCheck..."; \
		ls bin/muster bin/muster-mcp lib/core/*.sh lib/commands/*.sh lib/tui/*.sh lib/skills/*.sh | xargs -n 1 -P 4 shellcheck --shell=bash --severity=warning || exit 1; \
		find templates/hooks -name '*.sh' -print0 | xargs -0 -n 1 -P 4 shellcheck --shell=bash --severity=warning --exclude=SC1083,SC2034 || exit 1; \
		echo "ShellCheck passed"; \
	else \
		echo "shellcheck not installed, skipping (brew install shellcheck)"; \
	fi

manifest:
	@bash -c 'export MUSTER_ROOT=. && source lib/core/app_verify.sh && _app_manifest_generate'
	@echo "Generated .muster.manifest"

manifest-sign: manifest
	@bash -c 'export MUSTER_ROOT=. && source lib/core/colors.sh && source lib/core/logger.sh && source lib/core/payload_sign.sh && source lib/core/app_verify.sh && _app_manifest_sign'
	@echo "Signed .muster.manifest.sig"

manifest-verify:
	@bash -c 'export MUSTER_ROOT=. && source lib/core/colors.sh && source lib/core/logger.sh && source lib/core/payload_sign.sh && source lib/core/app_verify.sh && _app_verify_full && echo "All files verified" || echo "Verification failed"'
