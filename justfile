build:
    zig build

run:
    zig build run

install:
    cp zig-out/bin/y ~/.local/bin

lint:
    zig fmt

