# Convenience targets. Everything here is also runnable by hand — CI uses the
# by-hand form, because a Makefile that hides the command is a Makefile nobody
# can reproduce.

SHELL := /bin/sh

.PHONY: all check test lint syntax install uninstall

all: check

check: syntax lint test

syntax:
	sh -n lib/sysopt.sh
	sh -n bin/sysopt
	sh -n tests/run_tests.sh
	sh -n install.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -s sh -S warning bin/sysopt lib/sysopt.sh tests/run_tests.sh install.sh; \
	else \
	  echo "shellcheck not installed — skipped (CI runs it)"; \
	fi

test:
	sh tests/run_tests.sh

install:
	sh install.sh

uninstall:
	sh install.sh --uninstall
