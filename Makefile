VASM_ARCHIVE := third_party/f030dsp3d/tools/vasm.tar.gz
VLINK_ARCHIVE := third_party/f030dsp3d/tools/vlink.tar.gz
DSP_TOOL_SOURCE := third_party/f030dsp3d/tools/asm56k
TOS_ROM := third_party/f030dsp3d/tools/tos402.rom

TOOLS_DIR := build/tools
VASM_DIR := $(TOOLS_DIR)/vasm
VLINK_DIR := $(TOOLS_DIR)/vlink
VASM := $(VASM_DIR)/vasmm68k_mot
VLINK := $(VLINK_DIR)/vlink

# vlink's vendored dir.c calls chmod() from its _WIN32 branch without a
# declaration. MSVC, the compiler that branch was written for, accepted the
# implicit declaration; GCC 14 and later reject it outright, and the stock
# -std=c99 -pedantic also hides mingw's non-ANSI prototypes. gnu99 plus a
# forced io.h supplies the real declaration. The UNIX branch includes
# sys/stat.h and needs none of this, so only override on Windows hosts.
HOST_UNAME := $(shell uname -s)
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(HOST_UNAME)))
VLINK_MAKE_ARGS := COPTS="-std=gnu99 -O2 -fomit-frame-pointer -c -include io.h"
endif

M68K_BUILD := build/m68k
DSP_BUILD := build/dsp
GENERATED_BUILD := build/generated
RELEASE_DIR := release
ROMS_DIR ?= roms

DSP_STAGE2_IMAGE := $(GENERATED_BUILD)/dsp_stage2_image.i
TONE_TABLE := $(GENERATED_BUILD)/tone_table.inc

# LA32 profile spike: the native Munt oracle, the tables it dumps, and the
# DSP-side table image derived from them (see tools/la32_partial.py).
NATIVE_BUILD := build/native
MUNT_SRC := third_party/munt/mt32emu/src
LA32_ORACLE := $(NATIVE_BUILD)/la32_partial_oracle.exe
LA32_TABLE_DUMP := $(GENERATED_BUILD)/la32_tables.txt
LA32_TABLES := $(GENERATED_BUILD)/la32tabs.inc
LA32_PROFILE_DIR := build/la32-profile
LA32_REFERENCE_DIR := build/reference
CXX ?= g++

M68K_SOURCES := \
	src/m68k/main.s \
	src/m68k/dsp_link.s
M68K_OBJECTS := $(patsubst src/m68k/%.s,$(M68K_BUILD)/%.o,$(M68K_SOURCES))
VERBOSE_M68K_BUILD := build/m68k-verbose
VERBOSE_M68K_OBJECTS := $(patsubst src/m68k/%.s,$(VERBOSE_M68K_BUILD)/%.o,$(M68K_SOURCES))

DOSBOX ?= $(shell command -v dosbox-staging 2>/dev/null || command -v dosbox 2>/dev/null)

# Hatari selection, inherited from F030MXDRV. Stock Hatari hands the Falcon DSP
# two instruction cycles per emulated 68030 clock twice over, so the DSP56001
# runs at 32 MIPS instead of the hardware's 16, and its host-port wait states
# are 72-174 % of hardware depending on the access pattern. Every real-time
# result from such a build is measured against a machine that does not exist.
# The default is therefore the DSP-calibrated Hatari from the F030Arcade tree;
# see docs/hatari-timing.md. Override either variable:
#   make <target> F030ARCADE=/path/to/F030Arcade
#   make <target> HATARI=/path/to/hatari
F030ARCADE ?= $(HOME)/Work/F030Arcade
HATARI_ROOTS := $(F030ARCADE) $(abspath $(CURDIR)/../F030Arcade)
HATARI_CANDIDATES := $(foreach root,$(HATARI_ROOTS),$(foreach build,build build-ucrt64,\
	$(root)/third_party/hatari/$(build)/src/hatari \
	$(root)/third_party/hatari/$(build)/src/hatari.exe))
HATARI_CALIBRATED := $(firstword $(wildcard $(HATARI_CANDIDATES)))
HATARI ?= $(firstword $(HATARI_CALIBRATED) hatari)

# Hatari splits the program argument into a GEMDOS directory and a filename
# using the host's separator, so a forward-slash path mounts the wrong root on
# Windows and boots to the desktop instead of running the program - silently,
# with a zero exit status. Every target therefore cd's into the program's own
# directory and passes a bare filename, and spells every other path it hands
# Hatari absolutely through $(CURDIR).
#
# A missing calibrated build is not an error - every static gate still works -
# but a real-time result from a stock build describes a DSP running at twice
# the Falcon's speed, so say so rather than reporting it as a clean pass.
define require_hatari
	@if ! command -v $(HATARI) >/dev/null 2>&1; then \
		echo "error: $(1) target needs Hatari ($(HATARI))" >&2; \
		exit 1; \
	fi
	@if [ "$(abspath $(HATARI))" != "$(abspath $(HATARI_CALIBRATED))" ]; then \
		echo "warning: $(HATARI) is not the DSP-calibrated build; real-time" >&2; \
		echo "         results will describe a 32 MIPS DSP - see docs/hatari-timing.md" >&2; \
	fi
endef

DOSBOX_FLAGS ?= --noprimaryconf --set output=texture

.PHONY: all help host dsp reference check smoke run verbose clean tools \
	oracle profile-partial profile-partials

all: host dsp

help:
	@echo "Build targets:"
	@echo "  all        build the Falcon executable and the DSP image"
	@echo "  check      build everything and validate the generated artefacts"
	@echo "  smoke      run the non-interactive Hatari integration test"
	@echo "  run        launch the self-test executable in Hatari"
	@echo "  verbose    build the traced bring-up executable (mt32verb.tos)"
	@echo "  oracle     build the native Munt LA32 partial oracle"
	@echo "  profile-partial CFG=n"
	@echo "             profile one LA32 synth partial under Hatari and check"
	@echo "             its output against the oracle: runs 0-3 are the exact"
	@echo "             kernel, 4-7 the perceptual one, same configurations"
	@echo "  profile-partials"
	@echo "             the same for every run"
	@echo "  clean      remove generated build/ and release/ directories"
	@echo
	@echo "The DSP step needs DOSBox for Motorola's ASM56000 and a C++17"
	@echo "compiler for the oracle; the Hatari targets need the DSP-calibrated"
	@echo "build - see docs/hatari-timing.md."
	@echo
	@echo "MT-32 ROM images are never tracked here. Put them in $(ROMS_DIR)"
	@echo "(override with ROMS_DIR=path); see docs/mt32-ground-truth.md."

host: $(RELEASE_DIR)/f030mt32.tos $(RELEASE_DIR)/f030mt32.ttp

dsp: $(RELEASE_DIR)/la32.lod $(DSP_STAGE2_IMAGE)

reference: $(TONE_TABLE) $(LA32_TABLES)

oracle: $(LA32_ORACLE)

tools: $(VASM) $(VLINK)

# -----------------------------------------------------------------------------
# Host toolchain, bootstrapped from the archived sources in f030dsp3d
# -----------------------------------------------------------------------------

$(TOOLS_DIR)/.vasm-unpacked: $(VASM_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VASM): $(TOOLS_DIR)/.vasm-unpacked
	$(MAKE) -C $(VASM_DIR) CPU=m68k SYNTAX=mot

$(TOOLS_DIR)/.vlink-unpacked: $(VLINK_ARCHIVE)
	@mkdir -p $(TOOLS_DIR)
	tar -xf $< -C $(TOOLS_DIR)
	@touch $@

$(VLINK): $(TOOLS_DIR)/.vlink-unpacked
	$(MAKE) -C $(VLINK_DIR) $(VLINK_MAKE_ARGS)

# -----------------------------------------------------------------------------
# Generated references
# -----------------------------------------------------------------------------

$(TONE_TABLE): tools/generate_tone_table.py src/dsp/protocol.inc
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_tone_table.py \
		--entries $$(sed -n 's/^TONE_TABLE_WORDS *equ *\([0-9]*\).*/\1/p' \
			src/dsp/protocol.inc) > $@

# The oracle links Munt's integer LA32 wave generator and its tables
# directly; the tiny config.h stand-in spares a CMake configure of the
# whole library. LGPL code, build-time only, nothing of it reaches the Falcon.
$(LA32_ORACLE): tools/la32_partial_oracle.cpp tools/mt32emu_config/config.h \
		$(MUNT_SRC)/LA32WaveGenerator.cpp $(MUNT_SRC)/LA32WaveGenerator.h \
		$(MUNT_SRC)/Tables.cpp $(MUNT_SRC)/Tables.h
	@mkdir -p $(NATIVE_BUILD)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 \
		-Itools/mt32emu_config -I$(MUNT_SRC) \
		tools/la32_partial_oracle.cpp $(MUNT_SRC)/LA32WaveGenerator.cpp \
		$(MUNT_SRC)/Tables.cpp -o $@

$(LA32_TABLE_DUMP): $(LA32_ORACLE)
	@mkdir -p $(GENERATED_BUILD)
	$(LA32_ORACLE) --dump-tables > $@

$(LA32_TABLES): tools/la32_partial.py $(LA32_TABLE_DUMP)
	python3 tools/la32_partial.py tables --tables $(LA32_TABLE_DUMP) > $@

# -----------------------------------------------------------------------------
# DSP
# -----------------------------------------------------------------------------

$(DSP_BUILD)/BUILD.BAT: tools/BUILD_DSP.BAT src/dsp/la32.asm \
		src/dsp/stage2_loader.asm src/dsp/protocol.inc $(TONE_TABLE) \
		$(LA32_TABLES)
	@mkdir -p $(DSP_BUILD)
	cp tools/BUILD_DSP.BAT $(DSP_BUILD)/BUILD.BAT
	cp src/dsp/la32.asm $(DSP_BUILD)/LA32.ASM
	cp src/dsp/protocol.inc $(DSP_BUILD)/
	cp src/dsp/stage2_loader.asm $(DSP_BUILD)/LA32BOOT.ASM
	cp $(TONE_TABLE) $(DSP_BUILD)/tonetabs.inc
	cp $(LA32_TABLES) $(DSP_BUILD)/la32tabs.inc
	cp $(DSP_TOOL_SOURCE)/ASM56000.EXE $(DSP_TOOL_SOURCE)/CLDLOD.EXE \
		$(DSP_TOOL_SOURCE)/DOS4GW.EXE $(DSP_TOOL_SOURCE)/ioequ.inc $(DSP_BUILD)/
	@touch $@

$(DSP_BUILD)/.assembled: $(DSP_BUILD)/BUILD.BAT
	@if [ -z "$(DOSBOX)" ]; then \
		echo "error: DSP build needs dosbox-staging or dosbox" >&2; \
		exit 1; \
	fi
	@rm -f $(DSP_BUILD)/LA32.CLD $(DSP_BUILD)/LA32.LOD $(DSP_BUILD)/LA32.LST \
		$(DSP_BUILD)/LA32BOOT.CLD $(DSP_BUILD)/LA32BOOT.LOD \
		$(DSP_BUILD)/LA32BOOT.LST
	"$(DOSBOX)" $(DOSBOX_FLAGS) "$(abspath $(DSP_BUILD)/BUILD.BAT)"
	@test -s $(DSP_BUILD)/LA32.LOD
	@test -s $(DSP_BUILD)/LA32BOOT.LOD
	@touch $@

$(RELEASE_DIR)/la32.lod: $(DSP_BUILD)/.assembled
	@mkdir -p $(RELEASE_DIR)
	cp $(DSP_BUILD)/LA32.LOD $@

# The LA32 render loops occupy internal P:$0080-$01ff, the rest of the kernel
# P:$0200-$05ff, the small LA32 images P:$0700, and the tone table and the
# large LA32 tables sit at the P alias of their X/Y homes ($0800, $3000,
# $3600, $3c00, $4000, $7000). There is no reserved-table region and no
# free-island exception yet; the generator still refuses overlapping
# sections, which is what catches a kernel that grows into its own tables.
$(DSP_STAGE2_IMAGE): tools/generate_dsp_stage2.py $(DSP_BUILD)/.assembled
	@mkdir -p $(GENERATED_BUILD)
	python3 tools/generate_dsp_stage2.py \
		--bootstrap $(DSP_BUILD)/LA32BOOT.LOD \
		--program $(DSP_BUILD)/LA32.LOD > $@

# -----------------------------------------------------------------------------
# 68030
# -----------------------------------------------------------------------------

$(M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/verbose.i \
		src/m68k/protocol.i $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -Isrc/m68k -I$(GENERATED_BUILD) \
		-o $@ -L $(M68K_BUILD)/$*.lst

$(RELEASE_DIR)/f030mt32.tos: $(M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	# no -tos-fastload: the loader must clear the TPA, since the period
	# buffer and the transport state assume zero-initialized BSS
	$(VLINK) $(M68K_OBJECTS) -b ataritos -s -e start -o $@

$(RELEASE_DIR)/f030mt32.ttp: $(RELEASE_DIR)/f030mt32.tos
	cp $< $@

# Real-hardware bring-up build: every XBIOS/DSP handshake traced to the
# console. Each step prints its label before the call and its result after, so
# a hang leaves a dangling label naming the call that never returned.
$(VERBOSE_M68K_BUILD)/%.o: src/m68k/%.s src/m68k/xbios.i src/m68k/verbose.i \
		src/m68k/protocol.i $(DSP_STAGE2_IMAGE) $(VASM)
	@mkdir -p $(VERBOSE_M68K_BUILD)
	$(VASM) $< -quiet -Felf -m68030 -DVERBOSE_BOOT \
		-Isrc/m68k -I$(GENERATED_BUILD) -o $@ \
		-L $(VERBOSE_M68K_BUILD)/$*.lst

$(RELEASE_DIR)/mt32verb.tos: $(VERBOSE_M68K_OBJECTS) $(VLINK)
	@mkdir -p $(RELEASE_DIR)
	$(VLINK) $(VERBOSE_M68K_OBJECTS) -b ataritos -s -e start -o $@

verbose: $(RELEASE_DIR)/mt32verb.tos
	@file $(RELEASE_DIR)/mt32verb.tos

# -----------------------------------------------------------------------------
# Gates
# -----------------------------------------------------------------------------

check: all reference
	@test -s $(RELEASE_DIR)/f030mt32.tos
	@test -s $(RELEASE_DIR)/f030mt32.ttp
	@test -s $(RELEASE_DIR)/la32.lod
	@test -s $(DSP_STAGE2_IMAGE)
	@rg -q "^0 +Errors" $(DSP_BUILD)/LA32.LST
	@rg -q "^0 +Warnings" $(DSP_BUILD)/LA32.LST
	@rg -q "^0 +Errors" $(DSP_BUILD)/LA32BOOT.LST
	@rg -q "^0 +Warnings" $(DSP_BUILD)/LA32BOOT.LST
	@rg -q "^DSP_BOOT_WORDS equ " $(DSP_STAGE2_IMAGE)
	@rg -q "^DSP_STAGE2_PROGRAM_WORDS equ " $(DSP_STAGE2_IMAGE)
	@rg -q "^tone_table_image:" $(TONE_TABLE)
	@rg -q "^la32_cfg_image:" $(LA32_TABLES)
	@rg -q "^la32_unlog_image:" $(LA32_TABLES)
	# The two protocol headers are one contract in two syntaxes; only their
	# first line, which names the other file, may differ. Spelled without
	# process substitution so the recipe works under a plain /bin/sh.
	@sed 1d src/dsp/protocol.inc > $(GENERATED_BUILD)/protocol.dsp.body
	@sed 1d src/m68k/protocol.i > $(GENERATED_BUILD)/protocol.m68k.body
	@diff $(GENERATED_BUILD)/protocol.dsp.body \
		$(GENERATED_BUILD)/protocol.m68k.body
	@file $(RELEASE_DIR)/f030mt32.tos $(RELEASE_DIR)/la32.lod

# Score the whole boot and transport path from Hatari's own traces: the
# two-stage DSP load, the protocol handshake, the sound matrix, both audio
# sources, the block-ready token, and an orderly shutdown that hands the sound
# system back.
smoke: check
	$(call require_hatari,smoke)
	@rm -f build/hatari-smoke.log build/hatari-smoke.trace
	@cd $(RELEASE_DIR) && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy $(HATARI) \
		--machine falcon --dsp emu \
		--tos $(CURDIR)/$(TOS_ROM) --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--log-file $(CURDIR)/build/hatari-smoke.log \
		--trace-file $(CURDIR)/build/hatari-smoke.trace \
		--trace gemdos,dsp_host_interface,xbios \
		f030mt32.tos
	@rg -q "XBIOS 0x6E Dsp_ExecBoot" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x4d544c" build/hatari-smoke.trace   # "MTL" magic
	@rg -q "Transfer 0x4c4f41" build/hatari-smoke.trace          # "LOA" ack
	@rg -q "Direct Transfer 0x010000" build/hatari-smoke.trace   # PING
	@rg -q "Transfer 0x4d5401" build/hatari-smoke.trace          # "MT" v1
	@rg -q "XBIOS 0x80 Locksnd" build/hatari-smoke.trace
	@rg -q "XBIOS 0x89 Dsptristate\\(0x1, 0x0\\)" build/hatari-smoke.trace
	@rg -q "XBIOS 0x8B Devconnect\\(1, 0x8, 0, 2, 1\\)" build/hatari-smoke.trace
	@rg -q "Direct Transfer 0x030370" build/hatari-smoke.trace   # SET_TONE A440
	@rg -q "Direct Transfer 0x040000" build/hatari-smoke.trace   # START_TONE
	@rg -q "Direct Transfer 0x080000" build/hatari-smoke.trace   # QUERY_TIME
	@rg -q "Direct Transfer 0x090000" build/hatari-smoke.trace   # QUERY_PERIODS
	@rg -q "Direct Transfer 0x050000" build/hatari-smoke.trace   # START_STREAM
	@rg -q "Transfer 0x524459" build/hatari-smoke.trace          # "RDY" token
	@rg -q "Direct Transfer 0x100000" build/hatari-smoke.trace   # a +4096 sample
	@rg -q "Direct Transfer 0xf00000" build/hatari-smoke.trace   # a -4096 sample
	@rg -q "Direct Transfer 0x060000" build/hatari-smoke.trace   # REFILL_STREAM
	@rg -q "Direct Transfer 0x070000" build/hatari-smoke.trace   # STOP_AUDIO
	@rg -q "XBIOS 0x89 Dsptristate\\(0x0, 0x0\\)" build/hatari-smoke.trace
	@rg -q "XBIOS 0x81 Unlocksnd" build/hatari-smoke.trace
	@! rg -q "Modulo addressing result unpredictable|Illegal instruction" \
		build/hatari-smoke.log
	@echo "Hatari F030MT32 boot and transport smoke test: OK"

# Profile one LA32 synth partial: the 68030 arms the Hatari DSP profiler
# with a marker PING, the DSP renders configuration CFG, the debugger
# brackets the render loop and dumps the output buffer, and the Python tool
# compares that buffer with the Munt oracle word for word before the cycle
# report is trusted. The configuration reaches the program through
# PROFILE.CFG because Hatari's autostart carries no command tail.
LA32_PROFILE_RUN = $(LA32_PROFILE_DIR)/$(CFG)
LA32_PROFILE_REFERENCE = $(LA32_REFERENCE_DIR)/la32-partial-$(CFG).txt

profile-partial: check tools/profile_dsp.py tools/la32_partial.py
	$(call require_hatari,profile-partial)
	@test -n "$(CFG)" || { echo "error: profile-partial needs CFG=0..7" >&2; exit 1; }
	@rm -rf $(LA32_PROFILE_RUN)
	@mkdir -p $(LA32_PROFILE_RUN) $(LA32_REFERENCE_DIR)
	@$(LA32_ORACLE) $$(python3 tools/la32_partial.py oracle-args $(CFG)) \
		> $(LA32_PROFILE_REFERENCE)
	@python3 tools/profile_dsp.py prepare \
		--listing $(DSP_BUILD)/LA32.LST \
		--output-dir $(LA32_PROFILE_RUN) \
		--marker $$((0x01c000 + $(CFG))) \
		--start-symbol la32_$$(python3 tools/la32_partial.py loop $(CFG))_loop \
		--end-symbol la32_$$(python3 tools/la32_partial.py loop $(CFG))_done \
		--marker-space y --dump x:0x1000-0x1fff
	@printf '$(CFG)' > $(RELEASE_DIR)/PROFILE.CFG
	@cd $(RELEASE_DIR) && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy $(HATARI) \
		--machine falcon --dsp emu \
		--tos $(CURDIR)/$(TOS_ROM) --patch-tos true \
		--fast-boot true --fast-forward true --sound off \
		--confirm-quit false --run-vbls 1200 \
		--trace-file $(CURDIR)/$(LA32_PROFILE_RUN)/trace.txt \
		--trace dsp_host_interface \
		--parse $(CURDIR)/$(LA32_PROFILE_RUN)/start.ini \
		f030mt32.tos \
		> $(CURDIR)/$(LA32_PROFILE_RUN)/debug.log 2>&1 || { \
			rm -f $(RELEASE_DIR)/PROFILE.CFG; \
			tail -n 60 $(CURDIR)/$(LA32_PROFILE_RUN)/debug.log >&2; \
			exit 1; \
		}
	@rm -f $(RELEASE_DIR)/PROFILE.CFG
	@test -s $(LA32_PROFILE_RUN)/profile.txt || { \
		echo "error: Hatari did not capture the LA32 partial profile" >&2; \
		tail -n 60 $(LA32_PROFILE_RUN)/debug.log >&2; \
		exit 1; \
	}
	@python3 tools/la32_partial.py compare \
		--dump $(LA32_PROFILE_RUN)/debug.log \
		--oracle $(LA32_PROFILE_REFERENCE) $(CFG)
	# The exact kernel's reply must also carry the oracle's checksum through
	# the host port; the perceptual kernel's buffer differs by design.
	@if [ "$$(python3 tools/la32_partial.py kernel $(CFG))" = exact ]; then \
		rg -q "Transfer 0x$$(python3 tools/la32_partial.py expected-checksum \
			--oracle $(LA32_PROFILE_REFERENCE))" $(LA32_PROFILE_RUN)/trace.txt; \
	fi
	@python3 tools/profile_dsp.py report \
		--listing $(DSP_BUILD)/LA32.LST \
		--profile $(LA32_PROFILE_RUN)/profile.txt \
		--output $(LA32_PROFILE_RUN)/report.txt \
		--samples 2048 --sample-rate 32779.947916 \
		--unit-label "codec frame" \
		--title "DSP56001 LA32 synth partial, configuration $(CFG) ($$(python3 tools/la32_partial.py name $(CFG)))"

profile-partials:
	@for cfg in $$(seq 0 $$(( $$(python3 tools/la32_partial.py count) - 1 ))); do \
		$(MAKE) --no-print-directory profile-partial CFG=$$cfg || exit 1; \
	done

run: all
	$(call require_hatari,run)
	@cd $(RELEASE_DIR) && $(HATARI) --machine falcon --dsp emu \
		--tos $(CURDIR)/$(TOS_ROM) --patch-tos true --fast-boot true \
		f030mt32.tos

clean:
	rm -rf build $(RELEASE_DIR)
