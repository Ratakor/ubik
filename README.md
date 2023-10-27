# Ubik
A kernel

# TODO
- Add a checklist/roadmap
- Move tty and drivers out of kernel space
- Replace json with zon
- Provide compatibility with Linux ABI
- Support RISC-V64, aarch64 and x86_64
- Replace limine with a custom bootloader?

# Clone, build and run
Make sure to have `zig master`, `xorriso` and `qemu-system-x86` then run

```console
% git clone https://github.com/ratakor/ubik --recursive
% zig build run -Doptimize=ReleaseFast
```
