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

C3C       ?= $(if $(wildcard $(HOME)/.cache/c3src/build-llvm23-clang/c3c),$(HOME)/.cache/c3src/build-llvm23-clang/c3c,$(HOME)/c3bin/c3c)
C3C_LIB   ?= $(if $(wildcard $(HOME)/.cache/c3src/src/lib/std),$(HOME)/.cache/c3src/src/lib,$(HOME)/c3lib)
C3C_VER   := v0.8.4
C3C_URL   := https://github.com/c3lang/c3c/releases/download/$(C3C_VER)/c3-linux-static.tar.gz

BINARY    := pfrontc

# C3 0.8.4 and PEAR2 load LLVM/LLD dynamically in the reproducible setup.
C3_RUNTIME_ENV = PATH="$(LLVM23_BIN):$(LLVM23_DIR)/../llvm-runtime-lld-linux-x64/bin:$$PATH" LD_LIBRARY_PATH="$(LLVM23_LIBDIR)$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"

# PEAR backend links against the LLVM-C API.
#
# Use LLVM **23**. v0.8.4 replaced `default<O2>` with a hand-written pass
# pipeline whose attribute enum values are LLVM-23 numbering; against LLVM 19
# the compiler links fine but every -O1/-O2 build dies inside
# InstCombinePass::run -> CallBase::getArgOperandWithAttribute ("out of bounds
# memory access") — i.e. optimisation is broken in a way that looks like a code
# bug. Verified both ways: see A2A/from_agent3.md report #3.
#
# If only LLVM 19 is installed, overriding works, but expect -O1/-O2 to crash:
#     make LLVM_LIB=LLVM-19
LLVM23_DIR  ?= $(if $(wildcard $(HOME)/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64/lib/libLLVM.so.23.1),$(HOME)/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64,$(HOME)/.cache/llvm23)
LLVM23_LIBDIR ?= $(if $(wildcard $(LLVM23_DIR)/lib/libLLVM-23.so),$(LLVM23_DIR)/lib,$(LLVM23_DIR))
ifeq ($(wildcard $(LLVM23_LIBDIR)/libLLVM-23.so),)
LLVM_LIBDIR ?= /usr/lib/x86_64-linux-gnu
LLVM_LIB    ?= LLVM-19
else
LLVM_LIBDIR ?= $(LLVM23_LIBDIR)
LLVM_LIB    ?= LLVM-23
endif
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

# The slice of pfront that reads AIR text: what a backend (pear1c, airtool) links.
AIR_READ_CORE := pfront/pfront_core.c3 pfront/pear_ir/air_ir.c3 pfront/pear_ir/air_text.c3 \
             pfront/pear_ir/air_read.c3 pfront/pear_ir/air_facts.c3

# ── Top-level targets ───────────────────────────────────────────────────
.PHONY: all c3c test test-pfront test-conform test-exec test-pear test-pear2 test-pear2-exec check-pear2 test-harness test-experiments test-subtype test-type-store test-llvm-attrs test-air-contracts test-air test-air3 test-lowering airtool pear2c legacy-pear test-legacy clean legacy \
        runtime air-everything

all: $(BINARY)

# pfrontc ends at .air: no LLVM, no backend. Native code is pear1c (legacy/pear1) or PEAR 2.
$(BINARY): $(SOURCES) | c3c
	$(C3_RUNTIME_ENV) $(C3C) compile --stdlib $(C3C_LIB) $(SOURCES) --max-stack-object-size 262144 -o $(BINARY)

# ── Bootstrap c3c if missing ────────────────────────────────────────────
c3c:
	@if [ ! -x "$(C3C)" ] || [ ! -d "$(C3C_LIB)/std" ]; then \
	  echo "==> fetching c3c $(C3C_VER)"; \
	  mkdir -p $$(dirname $(C3C)) $(C3C_LIB) /tmp/c3i; \
	  cd /tmp/c3i && curl -sL $(C3C_URL) -o c3.tgz && tar -xzf c3.tgz; \
	  cp /tmp/c3i/c3/c3c $$(dirname $(C3C))/c3c; \
	  cp /tmp/c3i/c3/c3fmt $$(dirname $(C3C))/cfmt 2>/dev/null || true; \
	  chmod +x $$(dirname $(C3C))/c3c; \
	  rm -rf $(C3C_LIB)/std; \
	  cp -r /tmp/c3i/c3/lib/std $(C3C_LIB)/std; \
	  rm -f $(C3C_LIB)/std/std; \
	  rm -rf /tmp/c3i; \
	fi
	@$(C3C) --version | head -1

# ── Tests ───────────────────────────────────────────────────────────────
test: test-pfront test-conform test-pear test-pear2 test-exec test-harness test-experiments test-subtype test-type-store test-llvm-attrs test-air-contracts test-air test-air3 test-lowering

# Test the test infrastructure too: missing/crashing compilers must never
# produce a false EXPECT-CLEAN pass.
test-harness: $(BINARY) $(PEAR1)
	python3 -m unittest discover -s tests/harness -p 'test_*.py'

test-pfront: $(BINARY)
	@echo "==> tests/pfront regression"
	bash tests/pfront/run.sh

test-conform: $(BINARY)
	@echo "==> conformance"
	bash conformance/run.sh

# PEAR backend (pfrontc -> .air -> legacy pear1c) smoke tests: scalar recursion, loops,
# if/else, mutable rebinding, indexed byte stores/loads.
test-pear: $(BINARY) $(PEAR1)
	@echo "==> PEAR exec (pfrontc -> .air -> legacy pear1c)"
	bash tests/exec/pear/run.sh

# Execution suite: the only target that runs a COMPILED binary and checks its
# result. Covers the emit configuration matrix (-O0/-O1/-O2/-O3) plus per-case
# stdout/exit-code assertions; known-broken cases are tracked in
# tests/exec/XFAIL.tsv. Override the tier with PEAR_OPT=-O0.
test-exec: $(BINARY) $(PEAR1)
	@echo "==> exec suite (pfrontc -> .air -> pear1c -> native -> run)"
	bash tests/exec/run.sh

# Cross-cutting probes for theory contracts, diagnostics, and module loading.
test-experiments: $(BINARY)
	@echo "==> theory experiments"
	bash experiments/run.sh

test-subtype: $(BINARY)
	@echo "==> semantic subtype specification"
	./$(BINARY) --subtype-selftest

# Standalone C3 unit uses the same real modules, with only the CLI main removed.
# Exercise record ownership/index/budget safety at the nbe merge boundary.
test-type-store: c3c
	mkdir -p tmp/n3
	$(C3C) compile --stdlib $(C3C_LIB) $(filter-out pfront/pfront_main.c3,$(SOURCES)) tests/harness/type_store_records.c3 --max-stack-object-size 262144 -o tmp/n3/type-store-records
	./tmp/n3/type-store-records

# Check actual LLVM semantic attributes before any optimizer can infer them.
test-llvm-attrs: c3c
	mkdir -p tmp/n3
	$(C3C) compile --stdlib $(C3C_LIB) $(filter-out pfront/pfront_main.c3,$(SOURCES)) legacy/pear1/pear.c3 legacy/pear1/pear_link.c3 tests/harness/llvm_attributes.c3 --max-stack-object-size 262144 $(LDFLAGS) -o tmp/n3/llvm-attributes
	./tmp/n3/llvm-attributes

# Reject stale/forged contracts at the actual AIR boundary.
test-air-contracts: c3c
	mkdir -p tmp/n3
	$(C3C) compile --stdlib $(C3C_LIB) $(filter-out pfront/pfront_main.c3,$(SOURCES)) tests/harness/air_contracts.c3 --max-stack-object-size 262144 -o tmp/n3/air-contracts
	./tmp/n3/air-contracts

# ── Legacy PEAR 1 (AIR text -> LLVM 23 -> native) ───────────────────────
# The old backend, frozen, as its own program reading `.air`. It reads the
# files pfrontc writes; PEAR 2 reads the same files. Links LLVM; pfrontc does not.
PEAR1_SRC := legacy/pear1/pear.c3 legacy/pear1/pear_link.c3 legacy/pear1/pear1c_main.c3
PEAR1     := legacy/pear1/pear1c
legacy-pear: $(PEAR1)
$(PEAR1): $(PEAR1_SRC) $(AIR_READ_CORE) | c3c
	mkdir -p legacy/pear1
	$(C3C) compile --stdlib $(C3C_LIB) $(PEAR1_SRC) $(AIR_READ_CORE) --max-stack-object-size 262144 $(LDFLAGS) -o $(PEAR1)

# AIR 2.0 text tools: `airtool check|fmt|verify FILE.air`. No LLVM, no theory layer:
# only the IR, the text reader/writer and the validity rules.
AIR_CORE  := pfront/pfront_core.c3 pfront/pear_ir/air_ir.c3 pfront/pear_ir/air_text.c3 \
             pfront/pear_ir/air_write.c3 pfront/pear_ir/air_read.c3 pfront/pear_ir/air_facts.c3 \
             pfront/pear_ir/air_verify.c3 pfront/pear_ir/air_lint.c3 pfront/pear_ir/air_ll.c3 tools/air/airtool.c3
AIRTOOL   := tmp/airtool
airtool: $(AIRTOOL)
$(AIRTOOL): $(AIR_CORE) | c3c
	mkdir -p tmp
	$(C3C) compile --stdlib $(C3C_LIB) $(AIR_CORE) --max-stack-object-size 262144 -o $(AIRTOOL)

# PEAR 2 bootstrap backend. It is a separate executable and links the shared
# AIR reader/verifier plus LLVM 23; it does not link PEAR 1 or pfrontc.
PEAR2_BIN := pear2/pear2c
PEAR2_SRC := $(filter-out tools/air/airtool.c3,$(AIR_CORE)) pear2/pear2_types.c3 pear2/pear2_memory.c3 pear2/pear2_match.c3 pear2/pear2_control.c3 pear2/pear2_calls.c3 pear2/pear2_letrec.c3 pear2/pear2_opt.c3 pear2/pear2_cfg.c3 pear2/pear2_x64.c3 pear2/pear2_elf.c3 pear2/pear2_native.c3 pear2/pear2c_main.c3
PEAR2_LDFLAGS ?= -L $(LLVM23_LIBDIR) -l LLVM-23
LLVM23_BIN ?= $(LLVM23_DIR)/bin
PEAR2_CLANG ?= $(LLVM23_BIN)/clang
pear2c: $(PEAR2_BIN)
	ln -sf $(PEAR2_BIN) pear2c
$(PEAR2_BIN): $(PEAR2_SRC) | c3c
	@test -f "$(LLVM23_LIBDIR)/libLLVM-23.so" || { echo "PEAR2 requires LLVM 23 C API at $(LLVM23_LIBDIR); set LLVM23_DIR"; exit 1; }
	$(C3_RUNTIME_ENV) $(C3C) compile --stdlib $(C3C_LIB) $(PEAR2_SRC) --max-stack-object-size 262144 $(PEAR2_LDFLAGS) -o $(PEAR2_BIN)

PEAR2_OPT_TEST := tmp/pear2-opt-test
PEAR2_OPT_TEST_SRC := pfront/pfront_core.c3 pfront/pear_ir/air_ir.c3 pear2/pear2_opt.c3 tests/pear2/opt_test.c3
$(PEAR2_OPT_TEST): $(PEAR2_OPT_TEST_SRC) | c3c
	mkdir -p tmp
	$(C3_RUNTIME_ENV) $(C3C) compile --stdlib $(C3C_LIB) $(PEAR2_OPT_TEST_SRC) --max-stack-object-size 262144 -o $(PEAR2_OPT_TEST)

test-pear2: $(PEAR2_BIN) $(PEAR2_OPT_TEST)
	$(C3_RUNTIME_ENV) ./$(PEAR2_OPT_TEST)
	$(C3_RUNTIME_ENV) C3C="$(C3C)" LLVM23_BIN="$(LLVM23_BIN)" LLVM23_LIBDIR="$(LLVM23_LIBDIR)" PEAR2_CLANG="$(PEAR2_CLANG)" bash tests/pear2/run.sh ./$(PEAR2_BIN)

test-pear2-exec: $(BINARY) $(PEAR2_BIN) $(PEAR2_OPT_TEST) pear2c
	$(C3_RUNTIME_ENV) ./$(PEAR2_OPT_TEST)
	$(C3_RUNTIME_ENV) LLVM23_BIN="$(LLVM23_BIN)" LLVM23_LIBDIR="$(LLVM23_LIBDIR)" PEAR2_CLANG="$(PEAR2_CLANG)" BACKEND=./pear2c bash tests/exec/run.sh
	$(C3_RUNTIME_ENV) LLVM23_BIN="$(LLVM23_BIN)" LLVM23_LIBDIR="$(LLVM23_LIBDIR)" PEAR2_CLANG="$(PEAR2_CLANG)" BACKEND=./pear2c bash tests/exec/pear/run.sh

# Syntax/type-check PEAR2 and the structural optimizer harness without linking
# LLVM, then run LLVM-independent arithmetic model tests. This does not replace
# executing the optimizer or backend fixtures.
check-pear2: | c3c
	$(C3C) compile -C --no-entry --stdlib $(C3C_LIB) $(filter-out tools/air/airtool.c3,$(AIR_CORE)) pear2/pear2_types.c3 pear2/pear2_memory.c3 pear2/pear2_match.c3 pear2/pear2_control.c3 pear2/pear2_calls.c3 pear2/pear2_letrec.c3 pear2/pear2_opt.c3 pear2/pear2_cfg.c3 pear2/pear2_x64.c3 pear2/pear2_elf.c3 pear2/pear2_native.c3 pear2/pear2c_main.c3 --max-stack-object-size 262144
	$(C3C) compile -C --stdlib $(C3C_LIB) pfront/pfront_core.c3 pfront/pear_ir/air_ir.c3 pear2/pear2_opt.c3 tests/pear2/opt_test.c3 --max-stack-object-size 262144
	bash -n tests/pear2/run.sh
	python3 tests/pear2/signed_division_model_test.py

# AIR 2.0 contract: hand-written good/bad .air, the corpus emitted by pfrontc
# (canonical re-print, validity ledger) and the write->read round trip.
test-air: $(BINARY) $(AIRTOOL)
	@echo "==> AIR 2.0 text contract"
	bash tests/air/run.sh ./$(BINARY) $(AIRTOOL)

# AIR lowering table: one feature per program in tests/lowering, audit + verify + native exit code,
# with the known-failing cases recorded exactly (tests/lowering/KNOWN.tsv).
# AIR 3.0 low profile: hand-written good/bad .air + the reference consumer (.air -> .ll -> executable)
test-air3: $(BINARY) $(AIRTOOL)
	@echo "==> AIR 3.0 low profile (reference consumer)"
	bash tests/air3/run.sh $(AIRTOOL)
	@echo "==> AIR 3.0 lowering gate (pfrontc --emit-air-low -> LLVM -> run)"
	bash tests/air3/gate.sh

test-lowering: $(BINARY) $(AIRTOOL) $(PEAR1)
	@echo "==> AIR lowering table (audit, verify, native exit code)"
	bash tests/lowering/run.sh ./$(BINARY)

# Quick smoke: build + emit AIR for everything.pie kitchen sink
air-everything: $(BINARY)
	./$(BINARY) tmp/everything.pie --emit-air --strict-types || true

# ── Legacy pride1 ───────────────────────────────────────────────────────
legacy:
	$(MAKE) -C legacy/pride1 -f Makefile.old

# ── Clean ───────────────────────────────────────────────────────────────
clean:
	rm -f $(BINARY) $(PEAR2_BIN) pear2c
	rm -f tmp/*.air
	find . -name "*.air" -not -path "./docs/*" -not -path "./legacy/*" -not -path "./tests/pear2/*" -delete
