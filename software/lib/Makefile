# libfft Makefile
# Builds libfft.so (native or ARM cross-compile)

CC      ?= gcc
AR      ?= ar
CFLAGS  ?= -Wall -O2 -fPIC -g
LDFLAGS := -shared

TARGET  := libfft.so

.PHONY: all clean install

all: $(TARGET)

$(TARGET): libfft.c libfft.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

install:
	cp $(TARGET) /usr/local/lib/
	cp libfft.h /usr/local/include/
	ldconfig

clean:
	rm -f $(TARGET) *.o
