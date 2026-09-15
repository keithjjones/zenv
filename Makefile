# zenv
#
# `install` and `uninstall` hold no logic: they forward to install.sh and
# uninstall.sh, which is what keeps `make uninstall` and `zenv uninstall` from
# drifting apart -- they are the same code path with the same flags.

SHELL := /bin/sh

.PHONY: help install uninstall test selftest hostile check lint clean

help:
	@echo 'zenv make targets:'
	@echo '  install   copy zenv into ~/.local and add the rc block'
	@echo '  uninstall remove it again, and say what it leaves behind'
	@echo '  test      run the suite under sh, bash and zsh'
	@echo '  selftest  test the harness itself (deliberate failures; not part of test)'
	@echo '  hostile   run the suite with sandbox paths containing a space and a quote'
	@echo '  lint      shellcheck -s sh'
	@echo '  check     selftest + test + hostile + lint'
	@echo '  clean     remove leftover test sandboxes from TMPDIR'
	@echo
	@echo 'Useful arguments:'
	@echo '  make install ARGS="--root DIR"    put environments somewhere else'
	@echo '  make uninstall ARGS=--dry-run     the inventory, removing nothing'
	@echo '  make test ARGS="--shells zsh"     one shell only'
	@echo '  make test ARGS="--only path"      cases whose name contains "path"'
	@echo '  make test ARGS="--keep"           leave sandboxes behind to inspect'

install:
	@./install.sh $(ARGS)

uninstall:
	@./uninstall.sh $(ARGS)

test:
	@tests/run.sh $(ARGS)

# The harness's own gate: proves run.sh reports failures and the escape guard
# trips. Kept out of `test` because its fixtures fail on purpose.
selftest:
	@tests/selftest.sh

hostile:
	@tests/run.sh --hostile $(ARGS)

lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo 'shellcheck not found: brew install shellcheck' >&2; exit 1; }
	@shellcheck -s sh bin/zenv install.sh uninstall.sh \
		tests/run.sh tests/lib.sh tests/selftest.sh tests/test_*.sh
	@echo 'shellcheck: clean'

check: selftest test hostile lint

clean:
	@d="$${TMPDIR:-/tmp}"; \
	n=$$(find "$$d" /tmp -maxdepth 1 \
		\( -name 'zenv-sb.*' -o -name 'zenv-run.*' -o -name 'zenv-selftest.*' \) \
		2>/dev/null | wc -l | tr -d ' '); \
	find "$$d" /tmp -maxdepth 1 \
		\( -name 'zenv-sb.*' -o -name 'zenv-run.*' -o -name 'zenv-selftest.*' \) \
		-exec rm -rf {} + 2>/dev/null; \
	echo "removed $$n leftover test director(ies)"
