# ============================================================
# RV32I Makefile
# ============================================================
#
# CPU:
#   ISA  : RV32I
#   ABI  : ILP32
#   IMEM : 2 KiB
#   DMEM : 1 KiB
#
# Comandos:
#
#   make
#       Compila el firmware
#
#   make debug
#       Compila si es necesario y ejecuta debugger.py
#
#   make clean
#       Elimina archivos generados
#
# ============================================================


# ------------------------------------------------------------
# Toolchain
# ------------------------------------------------------------

CROSS := riscv64-unknown-elf

CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump
SIZE    := $(CROSS)-size

PYTHON  := python3


# ------------------------------------------------------------
# Directorios
# ------------------------------------------------------------

SRC_DIR    := src
INC_DIR    := inc
LINKER_DIR := linker
OUT_DIR    := out
TOOLS_DIR  := tools

LDSCRIPT := $(LINKER_DIR)/mem_map.ld

# ------------------------------------------------------------
# Programa
# ------------------------------------------------------------

PROGRAM := risc_v

ELF := $(OUT_DIR)/$(PROGRAM).elf
BIN := $(OUT_DIR)/$(PROGRAM).bin
HEX := $(OUT_DIR)/$(PROGRAM).hex
DIS := $(OUT_DIR)/$(PROGRAM).dis
MAP := $(OUT_DIR)/$(PROGRAM).map


# ------------------------------------------------------------
# Debugger
# ------------------------------------------------------------

DEBUGGER := $(TOOLS_DIR)/debugger.py

# ------------------------------------------------------------
# Memoria
# ------------------------------------------------------------

IMEM_BYTES := 2048


# ------------------------------------------------------------
# Arquitectura
# ------------------------------------------------------------

ARCH_FLAGS := \
	-march=rv32i \
	-mabi=ilp32 \
	-mcmodel=medlow \
	-msmall-data-limit=0 \
	-mno-save-restore \
	-mno-relax


# ------------------------------------------------------------
# Flags C
# ------------------------------------------------------------

BASE_CFLAGS := \
	$(ARCH_FLAGS) \
	-O2 \
	-g3 \
	-Wall \
	-Wextra \
	-ffreestanding \
	-fno-builtin \
	-fno-pic \
	-fno-pie \
	-fno-stack-protector \
	-fno-jump-tables \
	-fno-unwind-tables \
	-fno-asynchronous-unwind-tables \
	-ffunction-sections \
	-fdata-sections \
	-I$(INC_DIR)

CFLAGS := \
	$(BASE_CFLAGS) \
	-MMD \
	-MP


# ------------------------------------------------------------
# Flags ensamblador
# ------------------------------------------------------------

ASFLAGS := \
	$(ARCH_FLAGS) \
	-g3 \
	-ffreestanding \
	-I$(INC_DIR)


# ------------------------------------------------------------
# Flags linker
# ------------------------------------------------------------

LDFLAGS := \
	$(ARCH_FLAGS) \
	-nostdlib \
	-nostartfiles \
	-nodefaultlibs \
	-static \
	-Wl,-T,$(LDSCRIPT) \
	-Wl,-Map,$(MAP) \
	-Wl,--gc-sections \
	-Wl,--no-relax

LDLIBS := -lgcc


# ------------------------------------------------------------
# Fuentes
# ------------------------------------------------------------

C_SRCS := $(wildcard $(SRC_DIR)/*.c)
S_SRCS := $(wildcard $(SRC_DIR)/*.S)

C_OBJS := $(patsubst $(SRC_DIR)/%.c,$(OUT_DIR)/%.o,$(C_SRCS))
S_OBJS := $(patsubst $(SRC_DIR)/%.S,$(OUT_DIR)/%.o,$(S_SRCS))

OBJS := $(S_OBJS) $(C_OBJS)

ASMS := $(patsubst $(SRC_DIR)/%.c,$(OUT_DIR)/%.s,$(C_SRCS))

DEPS := $(C_OBJS:.o=.d)


# ============================================================
# Target principal
# ============================================================

all: check-toolchain $(HEX) $(DIS) info

asm: $(ASMS)

# ============================================================
# Directorio output
# ============================================================

$(OUT_DIR):	
	mkdir -p $(OUT_DIR)


# ============================================================
# C -> objeto
# ============================================================

$(OUT_DIR)/%.o: $(SRC_DIR)/%.c | $(OUT_DIR)
	$(CC) $(CFLAGS) -c $< -o $@


# ============================================================
# ASM -> objeto
# ============================================================

$(OUT_DIR)/%.o: $(SRC_DIR)/%.S | $(OUT_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@


# ============================================================
# C -> ASM legible
# ============================================================

$(OUT_DIR)/%.s: $(SRC_DIR)/%.c | $(OUT_DIR)
	$(CC) $(BASE_CFLAGS) -S -fverbose-asm $< -o $@


# ============================================================
# Link
# ============================================================

$(ELF): $(OBJS) $(LDSCRIPT)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)


# ============================================================
# ELF -> BIN
# ============================================================

$(BIN): $(ELF)
	$(OBJCOPY) \
		-O binary \
		--only-section=.text \
		$< $@

	@bytes=$$(stat -c%s $@); \
	if [ $$bytes -gt $(IMEM_BYTES) ]; then \
		echo "ERROR: IMEM overflow"; \
		echo "Programa: $$bytes bytes"; \
		echo "IMEM:     $(IMEM_BYTES) bytes"; \
		exit 1; \
	fi


# ============================================================
# BIN -> HEX
#
# Un byte hexadecimal por linea.
# ============================================================

$(HEX): $(BIN)
	@od -An -v -tx1 $< | \
	awk '{ for (i = 1; i <= NF; i++) print $$i }' > $@

	@bytes=$$(wc -l < $@); \
	if [ $$((bytes % 4)) -ne 0 ]; then \
		echo "ERROR: HEX no contiene un numero multiplo de 4 bytes"; \
		exit 1; \
	fi

	@echo ""
	@echo "HEX generado: $(HEX)"
	@echo "Uso IMEM:     $$(wc -l < $(HEX)) / $(IMEM_BYTES) bytes"


# ============================================================
# Desensamblado
# ============================================================

$(DIS): $(ELF)
	$(OBJDUMP) -d -S -M no-aliases,numeric $< > $@


# ============================================================
# Debugger
# ============================================================
#
# make debug
#
# Si firmware.hex no existe o esta desactualizado, primero
# recompila. Luego ejecuta debugger.py.
#
# ============================================================

debug: $(HEX)
	$(PYTHON) $(DEBUGGER)


# ============================================================
# Informacion
# ============================================================

info: $(ELF) $(HEX)
	@echo ""
	@echo "============================================================"
	@echo " RV32I "
	@echo "============================================================"
	$(SIZE) $(ELF)
	@echo ""
	@echo "ELF : $(ELF)"
	@echo "HEX : $(HEX)"
	@echo "DIS : $(DIS)"
	@echo "MAP : $(MAP)"
	@echo ""
	@echo "Ejecutar debugger:"
	@echo "  make debug"
	@echo "============================================================"


# ============================================================
# Verificar toolchain
# ============================================================

check-toolchain:
	@command -v $(CC) >/dev/null 2>&1 || { \
		echo "ERROR: no se encontro $(CC)"; \
		exit 1; \
	}

	@command -v $(OBJCOPY) >/dev/null 2>&1 || { \
		echo "ERROR: no se encontro $(OBJCOPY)"; \
		exit 1; \
	}

	@command -v $(OBJDUMP) >/dev/null 2>&1 || { \
		echo "ERROR: no se encontro $(OBJDUMP)"; \
		exit 1; \
	}

	@command -v $(PYTHON) >/dev/null 2>&1 || { \
		echo "ERROR: no se encontro $(PYTHON)"; \
		exit 1; \
	}


# ============================================================
# Limpieza
# ============================================================

clean:
	rm -f \
		$(OBJS) \
		$(DEPS) \
		$(ASMS) \
		$(ELF) \
		$(BIN) \
		$(HEX) \
		$(DIS) \
		$(MAP)


# Dependencias de headers
-include $(DEPS)

.PHONY: all asm clean debug info check-toolchain
