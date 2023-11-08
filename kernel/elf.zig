const std = @import("std");
const root = @import("root");
const pmm = root.pmm;
const vmm = root.vmm;
const page_size = std.mem.page_size;

pub const AuxVal = struct {
    entry: u64,
    phdr: u64,
    phent: u64,
    phnum: u64,
};

pub fn load(elf_addr: u64, addr_space: *vmm.AddressSpace, load_base: u64, ld_path: *[]u8) !AuxVal {
    const header = try std.elf.Header.parse(@ptrFromInt(elf_addr));

    if (!header.is_64 or header.endian != .Little or header.machine != .X86_64) {
        return error.InvalidElf;
    }

    var auxv: AuxVal = undefined;
    var iter = header.program_header_iterator();
    while (try iter.next()) |phdr| switch (phdr.p_type) {
        std.elf.PT_LOAD => {
            var prot: i32 = vmm.PROT.READ;
            if (phdr.p_flags & std.elf.PF_W) {
                prot |= vmm.PROT.WRITE;
            }
            if (phdr.p_flags & std.elf.PF_X) {
                prot |= vmm.PROT.EXEC;
            }

            const misalign = phdr.p_vaddr & (page_size - 1);
            const page_count = std.math.divCeil(phdr.p_memsz + misalign, page_size);

            const paddr = pmm.alloc(page_count, true) orelse return error.OutOfMemory;
            errdefer pmm.free(paddr, page_count);
            try addr_space.mmapRange(
                phdr.p_vaddr + load_base,
                paddr,
                page_count * page_size,
                prot,
                vmm.MAP.ANONYMOUS,
            );

            // TODO: read + map file
            // try res.read(null, phys + misalign + VMM_HIGHER_HALF, phdr.p_offset, phdr.p_filesz);
        },
        std.elf.PT_PHDR => {
            auxv.phdr = phdr.p_vaddr + load_base;
        },
        std.elf.PT_INTERP => {
            if (ld_path) |ldp| {
                root.allocator.allocSentinel(u8, phdr.p_filesz, 0);
                const path = try root.allocator.alloc(u8, phdr.p_filesz + 1);
                errdefer root.allocator.free(path);
                // TODO
                // try res.read(null, @intFromPtr(path), phdr.p_offset, phdr.p_filesz);
                ldp = path;
                @panic("Not Implemented");
            }
        },
        else => {},
    };

    auxv.entry = header.entry + load_base;
    auxv.phent = header.phentsize;
    auxv.phnum = header.phnum;

    return auxv;
}
