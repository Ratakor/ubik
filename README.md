# Ubik
A kernel

# TODO
- Rework VMM -> rework sched -> work on VFS -> work on ELF
- Add a checklist/roadmap
- Move tty and drivers out of kernel space
- Replace json with zon
- Replace unreachable with @panic
- Provide compatibility with Linux ABI
- Support RISC-V64, aarch64 and x86_64
- Replace @import("root") with @import("main.zig") to allow for testing
- Replace limine with a custom bootloader?
- write core in zig and the rest in nov

# Clone, build and run
Use Zig **0.16.0** (with LLVM support), `xorriso`, `make`, a C compiler,
and `qemu-system-x86_64`, then run

```console
% git clone git@github.com:ratakor/ubik --recursive
% zig build run
```

# Host regression tests
These tests cover locking, page/heap allocation, VMM, serial/TTY I/O, and debug
helpers using mocked hardware. They do not execute privileged instructions or
replace SMP boot testing. Run from the repository root:

```console
zig build test
```

The kernel uses Zig's LLVM backend for its interrupt-stub inline assembly.
Historical Limine protocol bindings are vendored in `lib/limine`; the bootloader
submodule is still required to build the ISO. Panic diagnostics retain DWARF
source lookup using frame pointers. Heap safety checks remain enabled in safe
builds, but hosted allocator stack-trace capture is disabled.

# File structure
This shouldn't be in readme.
TODO: move init function at the end of file (or top?)

1. imports
2. type definitions
3. constants
4. variables
5. init function
6. pub functions
7. other functions
