TOP       ?= tb_system
OUTDIR    ?= build
SRCDIR    := ../rtl
TBDIR     := ../tb

RTL_SRCS  := $(SRCDIR)/spram.sv \
             $(SRCDIR)/pe.sv \
             $(SRCDIR)/array4x4.sv \
             $(SRCDIR)/controller.sv \
             $(SRCDIR)/systolic_top.sv
TB_SRCS   := $(TBDIR)/tb_system.sv

all: build run

prep:
	mkdir -p $(OUTDIR)

build: prep
	vcs -full64 -sverilog +v2k +lint=all -timescale=1ns/1ps \
	    -debug_access+all \
	    -l $(OUTDIR)/compile.log \
	    $(RTL_SRCS) $(TB_SRCS) \
	    -o $(OUTDIR)/simv

run:
	$(OUTDIR)/simv -l $(OUTDIR)/run.log

wave:
	dve -full64 -vpd vcdplus.vpd &

clean:
	rm -rf $(OUTDIR) csrc simv.daidir ucli.key vcdplus.vpd waves.vcd

.PHONY: all prep build run wave clean
