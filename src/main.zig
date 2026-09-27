const std = @import("std");

const Cpu = struct { register: [32]u32, pc: u32, memory: [1024 * 1024]u8 };

pub fn main() !void {
    // 创建一台虚拟机，带有32位寄存器和1MiB的内存
    var machine = Cpu{ .register = [_]u32{0} ** 32, .pc = 0, .memory = [_]u8{0} ** (1024 * 1024) };
    std.debug.print("The Machine:\n", .{});
    std.debug.print("pc = {d}\n", .{machine.pc});
    std.debug.print("register[0] = {d}\n", .{machine.register[0]});
    std.debug.print("memory[0x00000010] = {d}\n\n", .{machine.memory[0x00000010]});

    // 测试一个取指
    machine.memory[0] = 0x13;
    machine.memory[1] = 0x00;
    machine.memory[2] = 0x70;
    machine.memory[3] = 0x00;
    const instruction = try fetch(machine);
    std.debug.print("Try fetch: instruction = 0x{x:0>8}\n\n", .{instruction});

    // 测试一个解码
    const decoded: IShapedInstruction = idecode(instruction);
    std.debug.print("Decoded: \n", .{});
    std.debug.print("imm = {d}\n", .{decoded.imm});
    std.debug.print("rs1 = {d}\n", .{decoded.rs1});
    std.debug.print("funct3 = {d}\n", .{decoded.funct3});
    std.debug.print("rd = {d}\n", .{decoded.rd});
    std.debug.print("opcode = 0x{x}\n\n", .{decoded.opcode});

    // 测试运行addi
    addi(decoded, &machine);
    std.debug.print("The result is in X10 = {d}\n\n", .{machine.register[decoded.rd]});
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

pub fn derun(raw_instruction: u32, machine: *Cpu) void {
    if (raw_instruction & 0x7F == 0x13) {
        const ins = idecode(raw_instruction);
        if (ins.funct3 == 0) {
            addi(ins, machine);
        }
        machine.pc += 4;
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
