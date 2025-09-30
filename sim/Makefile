# VCS-only flow with TB + generator in this directory
TOP_TB  := tb_system
OUTDIR  := build
RTL_DIR := ../rtl
PYTHON  := python3

RTL_SRCS := \
  $(RTL_DIR)/spram.sv \
  $(RTL_DIR)/pe.sv \
  $(RTL_DIR)/array4x4.sv \
  $(RTL_DIR)/controller.sv \
  $(RTL_DIR)/systolic_top.sv

TB_SRCS := tb_system.sv

HEX_4   := A_4.hex B_4.hex C_4_gold.hex
HEX_8   := A_8.hex B_8.hex C_8_gold.hex
HEX_16  := A_16.hex B_16.hex C_16_gold.hex
ALL_HEX := $(HEX_4) $(HEX_8) $(HEX_16)

.PHONY: all gen build run clean
all: gen build run

# 1) Generate Q1.15 inputs & goldens into current dir
gen: $(ALL_HEX)

$(HEX_4):
	$(PYTHON) gen.py --N 4  --seed 0xC0FFEE --dump_hex --outdir .

$(HEX_8):
	$(PYTHON) gen.py --N 8  --seed 0xC0FFEE --dump_hex --outdir .

$(HEX_16):
	$(PYTHON) gen.py --N 16 --seed 0xC0FFEE --dump_hex --outdir .

# 2) Build with VCS
build: $(OUTDIR)/simv
$(OUTDIR)/simv: $(RTL_SRCS) $(TB_SRCS) | $(OUTDIR)
	vcs -full64 -sverilog +v2k +lint=all -timescale=1ns/1ps \
	    -debug_access+all -l $(OUTDIR)/compile.log \
	    $(RTL_SRCS) $(TB_SRCS) -o $(OUTDIR)/simv
$(OUTDIR):
	mkdir -p $(OUTDIR)

# 3) Run
run: $(OUTDIR)/simv $(ALL_HEX)
	$(OUTDIR)/simv -l $(OUTDIR)/run.log

clean:
	rm -rf $(OUTDIR) *.hex waves.vcd vcdplus.vpd csrc simv.daidir ucli.key
