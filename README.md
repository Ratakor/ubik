# Ubik
A kernel

# TODO
- Add a checklist/roadmap
- Provide compatibility with Linux ABI
- Don't make a monolithic kernel
- Support RISC-V64, aarch64 and x86_64
- Replace limine with a custom bootloader?

# Clone, build and run
Make sure to have `zig master`, `xorriso` and `qemu-system-x86` then run

```console
% git clone https://github.com/ratakor/ubik --recursive
% zig build run
```
