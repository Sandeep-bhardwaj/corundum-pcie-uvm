# SPDX-License-Identifier: BSD-2-Clause-Views
# mqnic UVM testbench - build entry point.
# Implements : VERIFICATION_STRATEGY.md  §16.3
# Introduced : Step 0
#
# This Makefile is a THIN WRAPPER around sim/scripts/sim_run.py, which holds the
# actual simulator command construction (§16.2). Everything here works
# identically by calling the Python scripts directly, which matters because make
# is not installed on a stock Windows host.

PYTHON      ?= python
SCRIPTS     := scripts
SIM         ?= questa
UVM_HOME    ?= $(CURDIR)/../ext/uvm
TIER        ?= smoke
TEST        ?= mqnic_base_test
SEED        ?= 1
VERBOSITY   ?= UVM_MEDIUM
WAVES       ?= 0
COVERAGE    ?= 0

RUNFLAGS := --sim $(SIM) --tier $(TIER) --test $(TEST) --seed $(SEED) \
            --verbosity $(VERBOSITY)
ifeq ($(WAVES),1)
RUNFLAGS += --waves
endif
ifeq ($(COVERAGE),1)
RUNFLAGS += --coverage
endif

.PHONY: help run dry lint lint-tb elab regress nightly coverage clean

help:
	@echo "targets:"
	@echo "  run       run one test      (TIER= TEST= SEED= WAVES=1 COVERAGE=1)"
	@echo "  dry       print sim commands without running"
	@echo "  lint      slang syntax check, testbench scope"
	@echo "  elab      slang full elaboration (needs UVM_HOME for UVM files)"
	@echo "  regress   run a tier regression   (TIER=)"
	@echo "  nightly   run the nightly list"
	@echo "  coverage  merge coverage databases"
	@echo "  clean     remove results/"

run:
	$(PYTHON) $(SCRIPTS)/sim_run.py $(RUNFLAGS)

dry:
	$(PYTHON) $(SCRIPTS)/sim_run.py $(RUNFLAGS) --dry-run

# Static checks. These need no simulator licence and are the fast inner loop.
lint:
	$(PYTHON) $(SCRIPTS)/slang_check.py --mode syntax --scope tb \
	    -f filelists/tb_common.f

lint-tb:
	$(PYTHON) $(SCRIPTS)/slang_check.py --mode syntax --scope tb --all

elab:
	$(PYTHON) $(SCRIPTS)/slang_check.py --mode elab --scope tb \
	    -f filelists/rtl_tier1a.f -f filelists/tb_common.f \
	    $(if $(UVM_HOME),--uvm-home $(UVM_HOME),)

# Regenerate the regression lists from the registered tests, and verify.
# A hand-maintained list stops covering what it does not mention, and says
# nothing when it does - see bug 20.
regress-lists:
	$(PYTHON) $(SCRIPTS)/gen_regress_lists.py

ral:
	$(PYTHON) $(SCRIPTS)/gen_ral.py

# Second front end on the RTL, using Icarus. Free, local, and independent of
# slang - two different parsers agreeing on 74 modules is worth more than one
# agreeing with itself. Icarus CANNOT run the UVM testbench (it does not
# support uvm_pkg); this checks the DESIGN only.
rtl-elab:
	@list=`grep -vE '^//|^\+|^$$' filelists/rtl_tier$(TIER).f | tr -d ''`; 	 cd filelists && iverilog -g2012 -s $(TOP_MODULE) -o /dev/null $$list && 	 echo "iverilog: rtl_tier$(TIER) elaborates clean"

check-lists:
	$(PYTHON) $(SCRIPTS)/gen_regress_lists.py --check
	$(PYTHON) $(SCRIPTS)/gen_ral.py --check
	$(PYTHON) $(SCRIPTS)/check_filelists.py

regress: check-lists
	$(PYTHON) $(SCRIPTS)/run_regression.py regress/tier$(TIER).list --sim $(SIM)

nightly: check-lists
	$(PYTHON) $(SCRIPTS)/run_regression.py regress/nightly.list --sim $(SIM) \
	    --coverage --seeds 1,2,3,4,5

coverage:
	MQNIC_SIM=$(SIM) bash $(SCRIPTS)/merge_coverage.sh

clean:
	rm -rf ../results
