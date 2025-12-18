UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
	EXT := dylib
else
	EXT := so
endif

.PHONY: build build-debug clean test

build:
	cargo build --release
	cp target/release/libtandem_ffi.$(EXT) lua/tandem_ffi.so

build-debug:
	cargo build
	cp target/debug/libtandem_ffi.$(EXT) lua/tandem_ffi.so

clean:
	cargo clean
	rm -f lua/tandem_ffi.so

test:
	cargo nextest run
