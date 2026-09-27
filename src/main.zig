const std = @import("std");

const Cpu = struct { register: [32]u32, pc: u32, memory: [1024 * 1024]u8 };

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    defer args.deinit();

    _ = args.next();

    const path = args.next() orelse {
        std.debug.print("Usage: zig run src/main.zig -- <Path to ELF>\n", .{});
        return error.MissingElfPath;
    };

    // 创建一台虚拟机，带有32位寄存器和1MiB的内存
    var machine = Cpu{ .register = [_]u32{0} ** 32, .pc = 0, .memory = [_]u8{0} ** (1024 * 1024) };
    std.debug.print("The Machine:\n", .{});
    std.debug.print("pc = {d}\n", .{machine.pc});
    std.debug.print("register[0] = {d}\n", .{machine.register[0]});
    std.debug.print("memory[0x00000010] = {d}\n\n", .{machine.memory[0x00000010]});

    const allocator = std.heap.page_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);

    std.debug.print("File size: {d} bytes\n\n", .{bytes.len});

    try loadfromfile(bytes, &machine);

    for (0..2) |_| {
        const instruction = try fetch(machine);
        std.debug.print("Try fetch: instruction = 0x{x:0>8}\n\n", .{instruction});
        try derun(instruction, &machine);
    }
    std.debug.print("Try decode and run.\nThe result is in result register = {d}\n", .{machine.register[10]});
    std.debug.print("Updated PC = {d}\n\n", .{machine.pc});
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

inline fn loadfromfile(bytes: []u8, machine: *Cpu) !void {
    // 检查文件头
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) {
        return error.NotELF;
    } else if (bytes.len < 52 or bytes[4] != 1 or bytes[5] != 1) {
        return error.NotELF32OrLittleEndianValue;
    } else {
        const e_type: u16 = @as(u16, bytes[16]) | (@as(u16, bytes[17]) << 8);
        const e_machine: u16 = @as(u16, bytes[18]) | (@as(u16, bytes[19]) << 8);
        if (e_type != 2 or e_machine != 243) {
            return error.NotRISCV;
        }
    }

    const e_entry: u32 = readU32(bytes, 24);
    const e_phoff: u32 = readU32(bytes, 28);
    const e_phnum: u16 = @as(u16, bytes[44]) | (@as(u16, bytes[45]) << 8);
    const e_phentsize: u16 = @as(u16, bytes[42]) | (@as(u16, bytes[43]) << 8);
    if (e_phentsize != 32) {
        return error.IsNotELF32;
    }

    for (0..e_phnum) |i| {
        const ph: usize = @as(usize, e_phoff) + i * @as(usize, e_phentsize);
        if (ph > bytes.len or bytes.len - ph < 32) {
            return error.FileHasNoHead;
        }

        const p_type = readU32(bytes, ph);
        const p_offset = readU32(bytes, ph + 4);
        const p_vaddr = readU32(bytes, ph + 8);
        const p_filesz = readU32(bytes, ph + 16);
        const p_memsz = readU32(bytes, ph + 20);

        if (p_type != 1) continue;

        const file_start: usize = @intCast(p_offset);
        const mem_start: usize = @intCast(p_vaddr);
        const file_size: usize = @intCast(p_filesz);
        const mem_size: usize = @intCast(p_memsz);

        if (file_size > mem_size) return error.FileSizeExceedsMemorySize;
        if (file_start > bytes.len or file_size > bytes.len - file_start)
            return error.FileIsTooSmall;
        if (mem_start > machine.memory.len or mem_size > machine.memory.len - mem_start)
            return error.MemoryIsTooSmall;

        // 装载内存
        @memcpy(machine.memory[mem_start .. mem_start + file_size], bytes[file_start .. file_start + file_size]);
        @memset(machine.memory[mem_start + file_size .. mem_start + mem_size], 0);
    }

    machine.pc = e_entry;
}

// Cpu取指
pub fn fetch(machine: Cpu) !u32 {
    if (machine.pc % 4 != 0) { //在RV32I中，一个指令的长度为4,所以应至少为4的倍数
        return error.UnalignedPc;
    } else if (machine.pc >= 1024 * 1024) { //这里检查内存是否越界，因为内存是1MiB刚好是4的倍数，所以PC不太可能越界
        return error.PcOutOfBounds;
    } else {
        var instruction: u32 = 0x00000000;
        for (0..4) |i| {
            const offset: u32 = @intCast(i);
            const shift: u5 = @intCast(i * 8);
            const shifted: u32 = @as(u32, machine.memory[machine.pc + offset]) << shift; //这里进行左移，来把指令放到对应位置
            instruction |= shifted; //这里进行按位或来表示拼接
        }

        return instruction;
    }
}

pub fn derun(raw_instruction: u32, machine: *Cpu) !void {
    if (raw_instruction & 0x7F == 0x13) {
        const ins = idecode(raw_instruction);
        if (ins.funct3 == 0) {
            addi(ins, machine);
        } else {
            return error.UnsupportedIShapeInstruction;
        }
        machine.pc += 4;
    } else {
        return error.UnsupportedInstrucionShape;
    }
}

const IShapedInstruction = struct { imm: i12, rs1: u5, funct3: u3, rd: u5, opcode: u7 };

pub fn idecode(instruction: u32) IShapedInstruction {
    const raw_imm: u12 = @intCast(instruction >> 20);
    const signed_imm: i12 = @bitCast(raw_imm);
    const ishaped: IShapedInstruction = IShapedInstruction{ .imm = signed_imm, .rs1 = @intCast((instruction >> 15) & 0x1F), .funct3 = @intCast((instruction >> 12) & 0x7), .rd = @intCast((instruction >> 7) & 0x1F), .opcode = @intCast(instruction & 0x7F) };
    return ishaped;
}

pub fn addi(ins: IShapedInstruction, machine: *Cpu) void {
    if (ins.rd != 0) {
        const imm32: i32 = @intCast(ins.imm);
        const immu32: u32 = @bitCast(imm32);
        machine.register[ins.rd] = machine.register[ins.rs1] +% immu32;
    }
}
