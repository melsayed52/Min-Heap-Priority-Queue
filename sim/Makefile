# Simulation makefile (iverilog/vvp). Run from the repo root:
#   make -C sim            # quick smoke (few minutes)
#   make -C sim full SEED=101
#   make -C sim regress    # 6 full seeds, sequential
IVERILOG ?= iverilog
VVP      ?= vvp
SEED     ?= 1

RTL = ../rtl/pheap.v ../rtl/ram_dp.v
TB  = ../tb/tb_pheap.v

tb.vvp: $(TB) $(RTL)
	$(IVERILOG) -g2005 -o $@ -s tb_pheap $(TB) $(RTL)

quick: tb.vvp
	$(VVP) tb.vvp +quick +seed=$(SEED)

full: tb.vvp
	$(VVP) tb.vvp +seed=$(SEED)

regress: tb.vvp
	for s in 101 202 303 404 505 606; do $(VVP) tb.vvp +seed=$$s | tail -5; done

.PHONY: quick full regress
