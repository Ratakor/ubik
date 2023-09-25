# Système 9
an operating system made with zig using Ubik as its kernel

# TODO
- use flanterm
- current font is under GPL
- support RISC-V64, aarch64 and x86_64
- replace limine with a custom bootloader
- add a checklist/roadmap

### clone and build

    git clone https://github.com/ratakor/os --recursive

### build
Make sure to have `xorriso` and run

    zig build image -Doptimize=ReleaseFast

### run
Make sure to have `qemu` and run

    zig build run
