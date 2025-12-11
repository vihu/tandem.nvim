UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
	EXT := dylib
else
	EXT := so
endif

.PHONY: build build-debug server clean

build:
	cargo build --release -p tandem-ffi
	mkdir -p rust/tandem-ffi/lua
	cp target/release/libtandem_ffi.$(EXT) rust/tandem-ffi/lua/tandem_ffi.so

build-debug:
	cargo build -p tandem-ffi
	mkdir -p rust/tandem-ffi/lua
	cp target/debug/libtandem_ffi.$(EXT) rust/tandem-ffi/lua/tandem_ffi.so

server:
	cargo run -p tandem-server --release

clean:
	cargo clean
	rm -rf rust/tandem-ffi/lua
