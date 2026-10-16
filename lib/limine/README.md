# Vendored Limine bindings

Source: https://github.com/48cf/limine-zig
Revision: `7b29b6e6f6d35052f01ed3831085a39aae131705`
Original Zig package hash: `1220f946f839eab2ec49dca1c805ce72ac3e3ef9c47b3afcdecd1c05a7b35f66d277`

`limine.zig` is copied from that revision with C calling convention spellings
updated from `.C` to `.c` for Zig 0.16.0. `LICENSE` is unchanged. These
historical bindings match the checked-in 2024 Limine bootloader and protocol;
do not replace them with current upstream bindings without also reviewing the
bootloader and kernel protocol compatibility.

The root build imports `limine.zig` directly, avoiding legacy package metadata
that Zig 0.16.0 no longer accepts. See `LICENSE` for upstream attribution and
license terms.
