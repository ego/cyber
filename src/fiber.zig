// Copyright (c) 2023 Cyber (See LICENSE)

/// Fibers.

const cy = @import("cyber.zig");
const stdx = @import("stdx");
const std = @import("std");
const log = stdx.log.scoped(.fiber);
const Value = cy.Value;

pub const Fiber = extern struct {
    structId: cy.TypeId,
    rc: u32,
    prevFiber: ?*Fiber,
    stackPtr: [*]Value,
    stackLen: u32,
    /// If pc == NullId, the fiber is done.
    pc: u32,

    /// Contains framePtr in the lower 48 bits and adjacent 8 bit parentDstLocal.
    /// parentDstLocal:
    ///   Where coyield and coreturn should copy the return value to.
    ///   If this is the NullByteId, no value is copied and instead released.
    extra: u64,

    inline fn setFramePtr(self: *Fiber, ptr: [*]Value) void {
        self.extra = (self.extra & 0xff000000000000) | @ptrToInt(ptr);
    }

    inline fn getFramePtr(self: *const Fiber) [*]Value {
        return @intToPtr([*]Value, @intCast(usize, self.extra & 0xffffffffffff));
    }

    inline fn setParentDstLocal(self: *Fiber, parentDstLocal: u8) void {
        self.extra = (self.extra & 0xffffffffffff) | (@as(u64, parentDstLocal) << 48);
    }

    inline fn getParentDstLocal(self: *const Fiber) u8 {
        return @intCast(u8, (self.extra & 0xff000000000000) >> 48);
    }
};

pub fn allocFiber(vm: *cy.VM, pc: usize, args: []const cy.Value, initialStackSize: u32) linksection(cy.HotSection) !cy.Value {
    // Args are copied over to the new stack.
    var stack = try vm.alloc.alloc(Value, initialStackSize);
    // Assumes initial stack size generated by compiler is enough to hold captured args.
    // Assumes call start local is at 1.
    std.mem.copy(Value, stack[5..5+args.len], args);

    const obj = try cy.heap.allocPoolObject(vm);
    const parentDstLocal = cy.NullU8;
    obj.fiber = .{
        .structId = cy.FiberS,
        .rc = 1,
        .stackPtr = stack.ptr,
        .stackLen = @intCast(u32, stack.len),
        .pc = @intCast(u32, pc),
        .extra = @as(u64, @ptrToInt(stack.ptr)) | (parentDstLocal << 48),
        .prevFiber = undefined,
    };
    return Value.initPtr(obj);
}

/// Since this is called from a coresume expression, the fiber should already be retained.
pub fn pushFiber(vm: *cy.VM, curFiberEndPc: usize, curFramePtr: [*]Value, fiber: *cy.Fiber, parentDstLocal: u8) cy.vm.PcFramePtr {
    // Save current fiber.
    vm.curFiber.stackPtr = vm.stack.ptr;
    vm.curFiber.stackLen = @intCast(u32, vm.stack.len);
    vm.curFiber.pc = @intCast(u32, curFiberEndPc);
    vm.curFiber.setFramePtr(curFramePtr);

    // Push new fiber.
    fiber.prevFiber = vm.curFiber;
    fiber.setParentDstLocal(parentDstLocal);
    vm.curFiber = fiber;
    vm.stack = fiber.stackPtr[0..fiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + fiber.stackLen;
    // Check if fiber was previously yielded.
    if (vm.ops[fiber.pc].code == .coyield) {
        log.debug("fiber set to {} {*}", .{fiber.pc + 3, vm.framePtr});
        return .{
            .pc = vm.toPc(fiber.pc + 3),
            .framePtr = fiber.getFramePtr(),
        };
    } else {
        log.debug("fiber set to {} {*}", .{fiber.pc, vm.framePtr});
        return .{
            .pc = vm.toPc(fiber.pc),
            .framePtr = fiber.getFramePtr(),
        };
    }
}

pub fn popFiber(vm: *cy.VM, curFiberEndPc: usize, curFramePtr: [*]Value, retValue: Value) cy.vm.PcFramePtr {
    vm.curFiber.stackPtr = vm.stack.ptr;
    vm.curFiber.stackLen = @intCast(u32, vm.stack.len);
    vm.curFiber.pc = @intCast(u32, curFiberEndPc);
    vm.curFiber.setFramePtr(curFramePtr);
    const dstLocal = vm.curFiber.getParentDstLocal();

    // Release current fiber.
    const nextFiber = vm.curFiber.prevFiber.?;
    cy.arc.releaseObject(vm, @ptrCast(*cy.HeapObject, vm.curFiber));

    // Set to next fiber.
    vm.curFiber = nextFiber;

    // Copy return value to parent local.
    if (dstLocal != cy.NullU8) {
        vm.curFiber.getFramePtr()[dstLocal] = retValue;
    } else {
        cy.arc.release(vm, retValue);
    }

    vm.stack = vm.curFiber.stackPtr[0..vm.curFiber.stackLen];
    vm.stackEndPtr = vm.stack.ptr + vm.curFiber.stackLen;
    log.debug("fiber set to {} {*}", .{vm.curFiber.pc, vm.framePtr});
    return cy.vm.PcFramePtr{
        .pc = vm.toPc(vm.curFiber.pc),
        .framePtr = vm.curFiber.getFramePtr(),
    };
}

/// Unwinds the stack and releases the locals.
/// This also releases the initial captured vars since it's on the stack.
pub fn releaseFiberStack(vm: *cy.VM, fiber: *cy.Fiber) void {
    log.debug("release fiber stack", .{});
    var stack = fiber.stackPtr[0..fiber.stackLen];
    var framePtr = (@ptrToInt(fiber.getFramePtr()) - @ptrToInt(stack.ptr)) >> 3;
    var pc = fiber.pc;

    if (pc != cy.NullId) {

        // Check if fiber is still in init state.
        switch (vm.ops[pc].code) {
            .callFuncIC,
            .callSym => {
                if (vm.ops[pc + 11].code == .coreturn) {
                    const numArgs = vm.ops[pc - 4].arg;
                    for (fiber.getFramePtr()[5..5 + numArgs]) |arg| {
                        cy.arc.release(vm, arg);
                    }
                }
            },
            else => {},
        }

        // Check if fiber was previously on a yield op.
        if (vm.ops[pc].code == .coyield) {
            const jump = @ptrCast(*const align(1) u16, &vm.ops[pc+1]).*;
            log.debug("release on frame {} {} {}", .{framePtr, pc, pc + jump});
            // The yield statement already contains the end locals pc.
            runReleaseOps(vm, stack, framePtr, pc + jump);
        }
        // Unwind stack and release all locals.
        while (framePtr > 0) {
            pc = cy.vm.pcOffset(vm, stack[framePtr + 2].retPcPtr);
            framePtr = (@ptrToInt(stack[framePtr + 3].retFramePtr) - @ptrToInt(stack.ptr)) >> 3;
            const endLocalsPc = cy.vm.pcToEndLocalsPc(vm, pc);
            log.debug("release on frame {} {} {}", .{framePtr, pc, endLocalsPc});
            if (endLocalsPc != cy.NullId) {
                runReleaseOps(vm, stack, framePtr, endLocalsPc);
            }
        }
    }
    // Finally free stack.
    vm.alloc.free(stack);
}

fn runReleaseOps(vm: *cy.VM, stack: []const cy.Value, framePtr: usize, startPc: usize) void {
    var pc = startPc;
    while (vm.ops[pc].code == .release) {
        const local = vm.ops[pc+1].arg;
        // stack[framePtr + local].dump();
        cy.arc.release(vm, stack[framePtr + local]);
        pc += 2;
    }
}