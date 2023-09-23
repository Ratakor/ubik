# Système 9
x86_64 operating system in zig

# TODO
- use flanterm
- use zig instead of make
- current font is under GPL
- add a CI
- support RISC-V64, aarch64 and x86_64
- replace limine with a custom bootloader

# dependencies
- all: make, zig
- iso: xorriso
- hdd: gptfdisk, mtools
- run: qemu

# makefile targets

Running `make all` will compile the kernel (from the `kernel/` directory) and
then generate a bootable ISO image.

Running `make all-hdd` will compile the kernel and then generate a raw image
suitable to be flashed onto a USB stick or hard drive/SSD.

Running `make run` will build the kernel and a bootable ISO (equivalent to make
all) and then run it using `qemu` (if installed).

Running `make run-hdd` will build the kernel and a raw HDD image (equivalent to
make all-hdd) and then run it using `qemu` (if installed).

The `run-uefi` and `run-hdd-uefi` targets are equivalent to their non `-uefi`
counterparts except that they boot `qemu` using a UEFI-compatible firmware.
