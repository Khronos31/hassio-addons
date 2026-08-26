# SPDX-License-Identifier: GPL-2.0-or-later
CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic -D_POSIX_C_SOURCE=200809L
CFLAGS += $(shell $(PKG_CONFIG) --cflags libusb-1.0)
LDLIBS += $(shell $(PKG_CONFIG) --libs libusb-1.0) -pthread

.PHONY: all clean test

all: siano-ts

siano-ts: siano-ts.o protocol.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

siano-ts.o: siano-ts.c protocol.h
protocol.o: protocol.c protocol.h

test-protocol: tests/test_protocol.o protocol.o
	$(CC) $(CFLAGS) -o $@ $^

tests/test_protocol.o: tests/test_protocol.c protocol.h

test: siano-ts test-protocol
	./test-protocol
	./tests/test_cli.sh

clean:
	rm -f siano-ts test-protocol *.o tests/*.o tests/.cli-error
