# ============================================================================
# Makefile — Pride compiler (pfront)
# ============================================================================
# Pride is a self-hostable untyped systems language with classical-sequent-
# calculus (λ̄μμ̃) at its core. This Makefile builds `pfrontc`, the current
# compiler driver. (The previous monolithic `pride` driver that emitted LLVM
# directly is preserved under legacy/pride1/ for archaeology; it is not built
# by default.)
#
# Requirements:
#   c3c 0.8.4     — C3 compiler (https://c3-lang.org)
#                   Auto-fetched to ~/c3bin/c3c by `make c3c` if missing.
#
# Targets:
#   make              build ./pfrontc
#   make c3c          fetch c3c if missing (idempotent)
#   make test         build + run all test suites
#   make clean        remove build outputs + generated .air files
#   make legacy       build the legacy pride1 compiler under legacy/pride1/
# ============================================================================

C3C       ?= $(HOME)/c3bin/c3c
C3C_LIB   ?= $(HOME)/c3lib
C3C_VER   := v0.8.4
C3C_URL   := https://github.com/c3lang/c3c/releases/download/$(C3C_VER)/c3-linux-static.tar.gz

BINARY    := pfrontc

# PEAR calls the LLVM-C API. Keep the backend library overrideable for local
# toolchains while defaulting to the LLVM 19 ABI used by this branch.
LLVM_LIBDIR ?= /usr/lib/x86_64-linux-gnu
LLVM_LIB    ?= LLVM-19
LDFLAGS     := -L $(LLVM_LIBDIR) -l $(LLVM_LIB)

# ── Sources ──────────────────────────────────────────────────────────────
PFRONT    := $(wildcard pfront/*.c3)
PEAR_IR   := $(wildcard pfront/pear_ir/*.c3)
THEORY    := $(wildcard pfront/theory/*.c3) \
             $(wildcard pfront/theory/types/*.c3) \
             $(wildcard pfront/theory/meta/*.c3) \
             $(wildcard pfront/theory/effects/*.c3) \
             $(wildcard pfront/theory/rewrite/*.c3) \
             $(wildcard pfront/theory/lower/*.c3) \
             $(wildcard pfront/theory/analysis/*.c3)
SOURCES   := $(PFRONT) $(PEAR_IR) $(THEORY)

# ── Top-level targets ───────────────────────────────────────────────────
.PHONY: all c3c test test-pfront test-conform test-experiments test-legacy clean legacy \
        runtime air-everything

all: $(BINARY)

$(BINARY): $(SOURCES) | c3c
	# AirModule/PearCg contain >64 KiB fixed-capacity tables; raise C3's
	# compile-time local-object ceiling to cover those existing structs.
	$(C3C) compile --stdlib $(C3C_LIB) $(SOURCES) --max-stack-object-size 262144 $(LDFLAGS) -o $(BINARY)

# ── Bootstrap c3c if missing ────────────────────────────────────────────
c3c:
	@if [ ! -x "$(C3C)" ]; then \
	  echo "==> fetching c3c $(C3C_VER)"; \
	  mkdir -p $$(dirname $(C3C)) $$(dirname $(C3C_LIB)) /tmp/c3i; \
	  cd /tmp/c3i && curl -sL $(C3C_URL) -o c3.tgz && tar -xzf c3.tgz; \
	  cp /tmp/c3i/c3/c3c $$(dirname $(C3C))/c3c; \
	  cp /tmp/c3i/c3/c3fmt $$(dirname $(C3C))/cfmt; \
	  chmod +x $$(dirname $(C3C))/c3c $$(dirname $(C3C))/cfmt; \
	  rm -rf $$(dirname $(C3C_LIB))/std; \
	  cp -r /tmp/c3i/c3/lib/* $$(dirname $(C3C_LIB))/; \
	  rm -f $$(dirname $(C3C_LIB))/std/std; \
	  ln -sf $$(dirname $(C3C)) $$HOME/c3bin; \
	  ln -sf $$(dirname $(C3C_LIB)) $$HOME/c3lib; \
	  rm -rf /tmp/c3i; \
	fi
	@$(C3C) --version | head -1

# ── Tests ───────────────────────────────────────────────────────────────
test: test-pfront test-conform test-experiments

test-pfront: $(BINARY)
	@echo "==> tests/pfront regression"
	bash tests/pfront/run.sh

test-conform: $(BINARY)
	@echo "==> conformance"
	bash conformance/run.sh

# Cross-cutting probes for theory contracts, diagnostics, and module loading.
# These run quickly and catch capability drift not covered by parser cases.
test-experiments: $(BINARY)
	@echo "==> theory experiments"
	bash experiments/run.sh

# Quick smoke: build + emit AIR for everything.pie kitchen sink
air-everything: $(BINARY)
	./$(BINARY) tmp/everything.pie --emit-air --strict-types || true

# ── Legacy pride1 ───────────────────────────────────────────────────────
legacy:
	$(MAKE) -C legacy/pride1 -f Makefile.old

# ── Clean ───────────────────────────────────────────────────────────────
clean:
	rm -f $(BINARY)
	rm -f tmp/*.air
	find . -name "*.air" -not -path "./docs/*" -not -path "./legacy/*" -delete
