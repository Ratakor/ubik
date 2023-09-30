# Système 9
an operating system made with zig using Ubik as its kernel

# TODO
- use flanterm
- support RISC-V64, aarch64 and x86_64
- replace limine with a custom bootloader
- add a checklist/roadmap

### clone

    git clone https://github.com/ratakor/os --recursive

### build
Make sure to have `xorriso` and run

    zig build image -Doptimize=ReleaseSafe

### run
Make sure to have `qemu` and run

    zig build run
