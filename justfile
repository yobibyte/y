build:
    zig build

run:
    zig build run

install:
    cp zig-out/bin/y ~/.local/bin/cy

lint:
    zig fmt {{justfile_directory()}}/src

lines:
    find src/ -type f ! -name '*.swp' -exec wc -l {} +

test:
    zig test {{justfile_directory()}}/test.zig
