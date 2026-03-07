SCHEME = $(HOME)/.local/bin/scheme
# Clone from https://github.com/ober/gherkin and build, then set GHERKIN_DIR
GHERKIN = $(or $(GHERKIN_DIR),$(CURDIR)/gherkin-latest/src)
LIBDIRS = src:$(GHERKIN)
COMPILE = LD_LIBRARY_PATH=.:$$LD_LIBRARY_PATH $(SCHEME) -q --libdirs $(LIBDIRS) --compile-imported-libraries
COMPILE_OPT = LD_LIBRARY_PATH=.:$$LD_LIBRARY_PATH $(SCHEME) -q --libdirs $(LIBDIRS) --compile-imported-libraries --optimize-level 3

.PHONY: all compile gherkin ffi binary clean compat compat-smoke compat-tier0 compat-tier1 compat-tier2 help

all: ffi gherkin compile

# Step 1: Compile C FFI shim
ffi: libgsh-ffi.so
libgsh-ffi.so: ffi-shim.c
	gcc -shared -fPIC -o $@ $< -Wall -Wextra -O2

# Step 2: Translate .ss → .sls via gherkin compiler
gherkin: ffi
	$(COMPILE) < build-gherkin.ss

# Translate + compile with WPO + opt3 (for binary-opt target)
gherkin-opt: ffi
	(echo '#!chezscheme'; echo '(generate-wpo-files #t)(generate-inspector-information #f)(cp0-effort-limit 500)(cp0-score-limit 50)'; tail -n +2 build-gherkin.ss) | $(COMPILE_OPT)

# Step 3: Compile .sls → .so via Chez
compile: gherkin
	$(COMPILE) < build-all.ss

# Build = full pipeline (translate + compile + link binary)
build: binary

# Native binary (clean removes .so/.wpo so WPO recompilation works)
binary: clean ffi gherkin
	$(SCHEME) -q --libdirs $(LIBDIRS) --program build-binary.ss

# Optimized native binary (opt3 + WPO + tuned cp0)
binary-opt: clean ffi gherkin-opt
	$(SCHEME) -q --libdirs $(LIBDIRS) --program build-binary.ss

# Run interpreted
run: all
	LD_LIBRARY_PATH=.:$$LD_LIBRARY_PATH $(SCHEME) -q --libdirs $(LIBDIRS) --program gsh.ss

# --- Compatibility tests (oils spec files from gerbil-shell submodule) ---
OILS_DIR = gerbil-shell/_vendor/oils

$(OILS_DIR):
	$(MAKE) -C gerbil-shell _vendor/oils

compat-smoke: $(OILS_DIR)
	python3 test/run_spec.py $(OILS_DIR)/spec/smoke.test.sh /bin/bash ./gsh

compat-tier0: $(OILS_DIR)
	@echo "=== Tier 0: Core POSIX ==="
	@for spec in smoke pipeline redirect builtin-eval-source command-sub comments exit-status; do \
		echo "--- $$spec ---"; \
		python3 test/run_spec.py $(OILS_DIR)/spec/$$spec.test.sh /bin/bash ./gsh || true; \
	done

compat-tier1: $(OILS_DIR)
	@echo "=== Tier 1: Variables & Expansion ==="
	@for spec in here-doc quote word-split var-sub arith tilde assign; do \
		echo "--- $$spec ---"; \
		python3 test/run_spec.py $(OILS_DIR)/spec/$$spec.test.sh /bin/bash ./gsh || true; \
	done

compat-tier2: $(OILS_DIR)
	@echo "=== Tier 2: Advanced ==="
	@for spec in glob brace-expansion case_ if_ for-expr loop sh-func builtin-special subshell command-parsing; do \
		echo "--- $$spec ---"; \
		python3 test/run_spec.py $(OILS_DIR)/spec/$$spec.test.sh /bin/bash ./gsh || true; \
	done

compat: compat-tier0 compat-tier1 compat-tier2

compat-one: $(OILS_DIR)
	python3 test/run_spec.py $(OILS_DIR)/spec/$(SPEC).test.sh /bin/bash ./gsh

clean:
	rm -f libgsh-ffi.so ffi-shim.o gsh-main.o gsh-kernel gsh_program.h
	rm -f gsh.boot gsh-all.so gsh.so gsh.wpo
	rm -f petite.boot scheme.boot
	rm -f src/gsh/*.sls.bak
	find src -name '*.so' -o -name '*.wpo' | xargs rm -f 2>/dev/null || true
	# Remove generated .sls files (keep handwritten ones)
	rm -f src/gsh/ast.sls src/gsh/registry.sls src/gsh/macros.sls src/gsh/util.sls
	rm -f src/gsh/environment.sls src/gsh/lexer.sls src/gsh/arithmetic.sls src/gsh/glob.sls
	rm -f src/gsh/fuzzy.sls src/gsh/history.sls src/gsh/parser.sls src/gsh/functions.sls
	rm -f src/gsh/signals.sls src/gsh/expander.sls src/gsh/redirect.sls src/gsh/control.sls
	rm -f src/gsh/jobs.sls src/gsh/builtins.sls src/gsh/pipeline.sls src/gsh/executor.sls
	rm -f src/gsh/completion.sls src/gsh/prompt.sls src/gsh/lineedit.sls src/gsh/fzf.sls
	rm -f src/gsh/script.sls src/gsh/startup.sls src/gsh/main.sls

help:
	@echo "Targets:"
	@echo "  all       - Build FFI + translate .ss→.sls + compile .sls→.so"
	@echo "  build     - Build standalone binary (./gsh)"
	@echo "  binary    - Same as build"
	@echo "  run       - Run shell interpreted (no binary)"
	@echo "  ffi       - Compile C FFI shim only"
	@echo "  gherkin   - Translate .ss → .sls only"
	@echo "  compile   - Compile .sls → .so only"
	@echo "  clean     - Remove all build artifacts"
	@echo "  compat    - Run all compatibility tests"
	@echo "  compat-smoke - Run smoke tests only"
	@echo "  help      - Show this help"
