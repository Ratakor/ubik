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
Use Zig `0.14.0-dev.1637+8c232922b`, `xorriso`, `make`, a C compiler,
and `qemu-system-x86_64`, then run

```console
% git clone git@github.com:ratakor/ubik --recursive
% zig build run
```

# Host regression tests
These tests use mocked CPU and physical-memory interfaces; they do not execute
privileged instructions or replace SMP boot testing. Run from the repository root:

```console
zig test --test-runner kernel/test_runner.zig --dep harness=root -Mroot=kernel/lib/lock_test.zig
zig test --test-runner kernel/test_runner.zig --dep harness=root --dep ubik --dep lock -Mroot=kernel/mm/vmm_test.zig -Mubik=lib/ubik.zig -Mlock=kernel/lib/lock.zig
```

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
