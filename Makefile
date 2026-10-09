PREFIX ?= /usr/local
CC      = clang
CFLAGS  = -O2 -Wall -Wextra -fobjc-arc
LDFLAGS = -framework Foundation -framework CoreGraphics -framework IOKit

figment: figment.m
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

install: figment
	install -d $(PREFIX)/bin
	install -m 755 figment $(PREFIX)/bin/figment

clean:
	rm -f figment

.PHONY: install clean
