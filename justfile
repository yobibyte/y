build:
    zig build

run:
    zig build run

install:
    cp zig-out/bin/y ~/.local/bin/cy

lint:
    zig fmt

lines:
    find src/ -type f -exec wc -l {} +
