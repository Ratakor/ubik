const std = @import("std");
const ubik = @import("ubik");
const root = @import("root");
const arch = @import("arch.zig");
const pmm = root.pmm;
const vmm = root.vmm;
const page_size = pmm.page_size;

// TODO: could std.elf be useful?

pub const AuxVal = struct {
    entry: u64,
    phdr: u64,
    phent: u64,
    phnum: u64,
};

pub fn load(elf_addr: u64, addr_space: *vmm.AddressSpace, load_base: u64) !AuxVal {
    const header = try std.elf.Header.parse(@ptrFromInt(elf_addr));

    if (!header.is_64 or header.endian != arch.endian or header.machine != .X86_64) {
        return error.InvalidElf;
    }

    var auxv: AuxVal = undefined;
    // var iter = header.program_header_iterator();
    // while (try iter.next()) |phdr| switch (phdr.p_type) {
    const ph_tbl = @as([*]std.elf.Elf64_Phdr, @ptrFromInt(elf_addr + header.phoff))[0..header.phnum];
    for (ph_tbl) |phdr| switch (phdr.p_type) {
        std.elf.PT_LOAD => {
            var prot: i32 = ubik.PROT.READ;
            if (phdr.p_flags & std.elf.PF_W != 0) {
                prot |= ubik.PROT.WRITE;
            }
            if (phdr.p_flags & std.elf.PF_X != 0) {
                prot |= ubik.PROT.EXEC;
            }

            const misalign = phdr.p_vaddr & (page_size - 1);
            std.log.debug("a {} {}", .{ misalign, phdr.p_vaddr });
            const page_count = try std.math.divCeil(usize, phdr.p_memsz + misalign, page_size);

            const paddr = pmm.alloc(page_count, true) orelse return error.OutOfMemory;
            errdefer pmm.free(paddr, page_count);
            try addr_space.mmapRange(
                phdr.p_vaddr + load_base,
                paddr,
                phdr.p_memsz,
                prot,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            );

            const dst: [*]u8 = @ptrFromInt(phdr.p_vaddr);
            const src: [*]u8 = @ptrFromInt(elf_addr + phdr.p_offset);
            @memcpy(dst[0..phdr.p_filesz], src[0..phdr.p_filesz]);
            @memset(dst[phdr.p_filesz..phdr.p_memsz], 0);

            // TODO: read + map file
            // try res.read(null, phys + misalign + VMM_HIGHER_HALF, phdr.p_offset, phdr.p_filesz);
        },
        std.elf.PT_PHDR => {
            auxv.phdr = phdr.p_vaddr + load_base;
        },
        std.elf.PT_INTERP => {
            // if (ld_path) |ldp| {
            //     root.allocator.allocSentinel(u8, phdr.p_filesz, 0);
            //     const path = try root.allocator.alloc(u8, phdr.p_filesz + 1);
            //     errdefer root.allocator.free(path);
            //     // TODO
            //     // try res.read(null, @intFromPtr(path), phdr.p_offset, phdr.p_filesz);
            //     ldp = path;
            //     @panic("Not Implemented");
            // }
        },
        else => {},
    };

    auxv.entry = header.entry + load_base;
    auxv.phent = header.phentsize;
    auxv.phnum = header.phnum;

    return auxv;
}
