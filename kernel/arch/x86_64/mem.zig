pub fn cpy(noalias dst: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.C) ?[*]u8 {
    @setRuntimeSafety(false);

    // cld?
    asm volatile (
        \\rep movsb
        :
        : [_] "{rdi}" (dst),
          [_] "{rsi}" (src),
          [_] "{rcx}" (len),
        : "rdi", "rsi", "rcx"
    );

    return dst;
}

pub fn set(dst: ?[*]u8, c: u8, len: usize) callconv(.C) ?[*]u8 {
    @setRuntimeSafety(false);

    // cld?
    asm volatile (
        \\rep stosb
        :
        : [_] "{rdi}" (dst),
          [_] "{rcx}" (len),
          [_] "{al}" (c),
        : "rdi", "rcx", "rax"
    );

    return dst;
}
