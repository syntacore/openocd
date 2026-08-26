# SPDX-License-Identifier: GPL-2.0-or-later

TOOLCHAIN:=mipsel-linux-gnu-
CC:=$(TOOLCHAIN)gcc
OBJCOPY:=$(TOOLCHAIN)objcopy
CFLAGS:=-O2 -Wall -Wextra -fpic -Wno-int-to-pointer-cast
SRC=dw-spi.c
OBJ=$(patsubst %.c, %.o,$(SRC))

# sparx-iv
ifeq ($(TOOLCHAIN),mipsel-linux-gnu-)
	CFLAGS+= -march=24kec
endif

ifeq ($(TOOLCHAIN),riscv64-linux-gnu-)
	CFLAGS+= -march=rv64im -mabi=lp64
endif

ifeq ($(TOOLCHAIN),riscv64-unknown-elf-)
	CFLAGS+= -march=rv64im -mabi=lp64 \
		-isystem /usr/lib/picolibc/riscv64-unknown-elf/include
endif

all: \
	$(TOOLCHAIN)transaction.inc \
	$(TOOLCHAIN)erase.inc \
	$(TOOLCHAIN)check_fill.inc \
	$(TOOLCHAIN)program.inc \
	$(TOOLCHAIN)read.inc

$(TOOLCHAIN)%.bin: $(OBJ)
	$(OBJCOPY) --dump-section .$*=$@ $<

%.inc: %.bin
	xxd -i > $@ < $<

.PHONY: clean
clean:
	rm -rf .ccls-cache
	find . \( \
	-iname "*.o" \
	-o -iname "*.bin" \
	-o -iname "*.inc" \
	\) -delete
