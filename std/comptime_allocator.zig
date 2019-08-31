const assert = @import("std").debug.assert;
const testing = @import("std").testing;

test "incrementing int" {
   const S = struct {
   fn increment(value: i8) i8 {
      return value+1;
   }
   fn doTheTest() void {
      var x: i8 = 0;
      x = increment(x);
      x = increment(x);
      testing.expect(x == 2);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}

test "incrementing int via *int" {
   const S = struct {
   fn increment(value: *i8) void {
      value.* += 1;
   }
   fn doTheTest() void {
      var x: i8 = 0;
      increment(&x);
      increment(&x);
      testing.expect(x == 2);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}

test "incrementing int via **int" {
   const S = struct {
   fn increment(value: **i8) void {
      value.*.* += 1;
   }
   fn doTheTest() void {
      var x: i8 = 0;
      var x_ptr = &x;
      increment(&x_ptr);
      increment(&x_ptr);
      testing.expect(x == 2);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}

fn Pair(comptime T: type) type {
   return struct{x: T, y: T};
}
test "incrementing other int via @fieldParentPtr of *int"{
   const S = struct {
   fn increment_x(value: *i8) void {
      const pair: *Pair(i8) = @fieldParentPtr(Pair(i8), "y", value);
      pair.*.x += 1;
   }
   fn doTheTest() void {
      var pair = Pair(i8){.x = 0, .y = 0};
      increment_x(&pair.y);
      increment_x(&pair.y);
      testing.expect(pair.x == 2);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}

const Interface = struct {
   const Self = @This();
   increment: fn(*Self) void,
};
fn IValue(comptime T: type) type {
   return struct{value: T,
      const Self = @This();
      interface: Interface,
      fn increment(i: *Interface) void {var self = @fieldParentPtr(Self, "interface", i); self.*.value += 1;}
      fn init() Self {
         return Self{.value = 0,
            .interface = Interface{.increment = Self.increment}};
      }
   };
}
test "incrementing other int via interface"{
   const S = struct {
   fn increment(interface: *Interface) void {interface.increment(interface);}
   fn doTheTest() void {
      var x = IValue(i8).init();
      var interface = &x.interface;
      increment(interface);
      increment(interface);
      testing.expect(x.value == 2);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}


const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;


//pub fn SimpleFixedBufferAllocator(comptime max_alignment: u29) type {return PreAlignedTypedFixedBufferAllocator(max_alignment, u8);}
pub fn PreAlignedFixedBufferAllocator(comptime max_alignment: u29) type {
   return TypedPreAlignedFixedBufferAllocator(u8, max_alignment);
}
pub fn TypedPreAlignedFixedBufferAllocator(comptime T: type, comptime max_alignment: u29) type {
   assert(max_alignment >= @alignOf(T));
   return struct {
    const Self = @This();
    allocator: Allocator,
    end_index: usize,
    buffer: [] align(max_alignment) T,

    pub fn init(buffer: [] align(max_alignment) T) Self {
        return Self{
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .buffer = buffer,
            .end_index = 0,
        };
    }

    fn alloc(allocator: *Allocator, n: usize, alignment: u29) ![]u8 {
        if(alignment > max_alignment) return error.OutOfMemory;
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const index = self.end_index;
        const adjusted_index = mem.alignForward(index, @divFloor(alignment + @sizeOf(T)-1, @sizeOf(T)));
        const new_end_index = adjusted_index + @divExact(n, @sizeOf(T));
        if (new_end_index > self.buffer.len) {
            return error.OutOfMemory;
        }
        const result = @ptrCast([*]u8, self.buffer.ptr)[std.math.mul(usize, adjusted_index, @sizeOf(T)) catch unreachable .. std.math.mul(usize, new_end_index, @sizeOf(T)) catch unreachable];
        self.end_index = new_end_index;

        return result;
    }

    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
        if(new_align > max_alignment) return error.OutOfMemory;
        assert(@mod(new_size, @sizeOf(T)) == 0);
        const self = @fieldParentPtr(Self, "allocator", allocator);
        assert(@divExact(old_mem.len, @sizeOf(T)) <= self.end_index);
        if(old_mem.len == 0) // so comptime never has to operate on old_mem.ptr and old_align, which may be undefined
           return alloc(allocator, new_size, new_align);
        const old_mem_offset = @ptrToInt(old_mem.ptr) - @ptrToInt(self.buffer.ptr);
        const old_mem_index = @divExact(old_mem_offset, @sizeOf(T));
        if (old_mem_index == self.end_index - @divExact(old_mem.len, @sizeOf(T)) and // allocation is on top of our stack
            mem.alignForward(old_mem_index, @divExact(new_align, @sizeOf(T))) == old_mem_index) // allocation is already aligned correctly
        {
            const new_end_index = old_mem_index + @divExact(new_size, @sizeOf(T));
            if (new_end_index > self.buffer.len) return error.OutOfMemory;
            const result = @ptrCast([*]u8, self.buffer.ptr)[old_mem_offset..std.math.mul(usize, new_end_index, @sizeOf(T)) catch unreachable];
            self.end_index = new_end_index;
            return result;
        } else if (new_size <= old_mem.len and new_align <= old_align) {
            // We can't do anything with the memory, so tell the client to keep it.
            return error.OutOfMemory;
        } else {
            const result = try alloc(allocator, new_size, new_align);
            @memcpy(result.ptr, old_mem.ptr, std.math.min(old_mem.len, result.len));
            return result;
        }
    }

    fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        return old_mem[0..new_size];
    }
   };
}
pub fn TypedFixedBufferAllocator(comptime T: type) type {
   return TypedPreAlignedFixedBufferAllocator(T, @alignOf(T));
}

test "std.ArrayList.init" {
   const S = struct{fn doTheTest() void {
    var bytes: [1024]u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;

    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    testing.expect(list.count() == 0);
    testing.expect(list.capacity() == 0);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}

test "std.ArrayList.basic" {
   const S = struct{fn doTheTest() void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;

    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    // setting on empty list is out of bounds
    testing.expectError(error.OutOfBounds, list.setOrError(0, 1));

    {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            list.append(@intCast(i32, i + 1)) catch unreachable;
        }
    }

    {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            testing.expect(list.items[i] == @intCast(i32, i + 1));
        }
    }

    for (list.toSlice()) |v, i| {
        testing.expect(v == @intCast(i32, i + 1));
    }

    for (list.toSliceConst()) |v, i| {
        testing.expect(v == @intCast(i32, i + 1));
    }

    testing.expect(list.pop() == 10);
    testing.expect(list.len == 9);

    list.appendSlice([_]i32{
        1,
        2,
        3,
    }) catch unreachable;
    testing.expect(list.len == 12);
    testing.expect(list.pop() == 3);
    testing.expect(list.pop() == 2);
    testing.expect(list.pop() == 1);
    testing.expect(list.len == 9);

    list.appendSlice([_]i32{}) catch unreachable;
    testing.expect(list.len == 9);

    // can only set on indices < self.len
    list.set(7, 33);
    list.set(8, 42);

    testing.expectError(error.OutOfBounds, list.setOrError(9, 99));
    testing.expectError(error.OutOfBounds, list.setOrError(10, 123));

    testing.expect(list.pop() == 42);
    testing.expect(list.pop() == 33);
   }};
   S.doTheTest();
   comptime S.doTheTest();
}


test "std.ArrayList.orderedRemove" {
   const S = struct{fn doTheTest() !void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);
    try list.append(6);
    try list.append(7);

    //remove from middle
    testing.expectEqual(i32(4), list.orderedRemove(3));
    testing.expectEqual(i32(5), list.at(3));
    testing.expectEqual(usize(6), list.len);

    //remove from end
    testing.expectEqual(i32(7), list.orderedRemove(5));
    testing.expectEqual(usize(5), list.len);

    //remove from front
    testing.expectEqual(i32(1), list.orderedRemove(0));
    testing.expectEqual(i32(2), list.at(0));
    testing.expectEqual(usize(4), list.len);
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}


test "std.ArrayList.swapRemove" {
   const S = struct{fn doTheTest() !void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.append(5);
    try list.append(6);
    try list.append(7);

    //remove from middle
    testing.expect(list.swapRemove(3) == 4);
    testing.expect(list.at(3) == 7);
    testing.expect(list.len == 6);

    //remove from end
    testing.expect(list.swapRemove(5) == 6);
    testing.expect(list.len == 5);

    //remove from front
    testing.expect(list.swapRemove(0) == 1);
    testing.expect(list.at(0) == 5);
    testing.expect(list.len == 4);
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}

test "std.ArrayList.swapRemoveOrError" {
   const S = struct{fn doTheTest() !void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    // Test just after initialization
    testing.expectError(error.OutOfBounds, list.swapRemoveOrError(0));

    // Test after adding one item and remote it
    try list.append(1);
    testing.expect((try list.swapRemoveOrError(0)) == 1);
    testing.expectError(error.OutOfBounds, list.swapRemoveOrError(0));

    // Test after adding two items and remote both
    try list.append(1);
    try list.append(2);
    testing.expect((try list.swapRemoveOrError(1)) == 2);
    testing.expect((try list.swapRemoveOrError(0)) == 1);
    testing.expectError(error.OutOfBounds, list.swapRemoveOrError(0));

    // Test out of bounds with one item
    try list.append(1);
    testing.expectError(error.OutOfBounds, list.swapRemoveOrError(1));

    // Test out of bounds with two items
    try list.append(2);
    testing.expectError(error.OutOfBounds, list.swapRemoveOrError(2));
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}

test "std.ArrayList.iterator" {
   const S = struct{fn doTheTest() !void {
   
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    var count: i32 = 0;
    var it = list.iterator();
    while (it.next()) |next| {
        testing.expect(next == count + 1);
        count += 1;
    }

    testing.expect(count == 3);
    testing.expect(it.next() == null);
    it.reset();
    count = 0;
    while (it.next()) |next| {
        testing.expect(next == count + 1);
        count += 1;
        if (count == 2) break;
    }

    it.reset();
    testing.expect(it.next().? == 1);
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}

test "std.ArrayList.insert" {
   const S = struct{fn doTheTest() !void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.insert(0, 5);
    testing.expect(list.items[0] == 5);
    testing.expect(list.items[1] == 1);
    testing.expect(list.items[2] == 2);
    testing.expect(list.items[3] == 3);
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}

test "std.ArrayList.insertSlice" {
   const S = struct{fn doTheTest() !void {
    var bytes: [1024] u8 align(@alignOf(i32)) = undefined;
    var allocator_object = PreAlignedFixedBufferAllocator(@alignOf(i32)).init(bytes[0..]);
    var allocator = &allocator_object.allocator;
    
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);
    try list.append(4);
    try list.insertSlice(1, [_]i32{
        9,
        8,
    });
    testing.expect(list.items[0] == 1);
    testing.expect(list.items[1] == 9);
    testing.expect(list.items[2] == 8);
    testing.expect(list.items[3] == 2);
    testing.expect(list.items[4] == 3);
    testing.expect(list.items[5] == 4);

    const items = [_]i32{1};
    try list.insertSlice(0, items[0..0]);
    testing.expect(list.len == 6);
    testing.expect(list.items[0] == 1);
   }};
   try S.doTheTest();
   comptime try S.doTheTest();
}

test "comptime resource test" {
   const S = struct{
      const foo = comptime blk: {
         const Foo = struct{
            bytes: [1024]u8,
            bytes1: []u8,
            bytes2: []u8,
         };
         var result = Foo{.bytes = undefined, .bytes1 = undefined, .bytes2 = undefined}; //Copy MUST be elided by result location of comptime block

         var allocator_object = TypedFixedBufferAllocator(u8).init(result.bytes[0..]);
         var allocator = &allocator_object.allocator;

         result.bytes1 = allocator.alloc(u8, 5) catch unreachable;
         result.bytes2 = allocator.alloc(u8, 10) catch unreachable;
         break :blk result;
      };
   };
   testing.expectEqual(usize(5), S.foo.bytes1.len);
   testing.expectEqual(usize(10), S.foo.bytes2.len);
   comptime testing.expectEqual(usize(5), S.foo.bytes1.len);
   comptime testing.expectEqual(usize(10), S.foo.bytes2.len);
}

test "comptime u32 resource test (with local workaround)" {
   const S = struct{
      const foo = comptime blk: {
         const Foo = struct{
            bytes: [1024]u32,
            bytes1: []u32,
            bytes2: []u32,
         };
         var result = Foo{.bytes = undefined, .bytes1 = undefined, .bytes2 = undefined}; //Copy MUST be elided by result location of comptime block

         var allocator_object = TypedFixedBufferAllocator(u32).init(result.bytes[0..]);
         var allocator = &allocator_object.allocator;

         // TODO
         // we need to re-slice these results, because we don't divide the byte slice in hackyComptimeBytesToSlice in mem.zig,
         // because when we do it triggers "error: cannot store runtime value in compile time variable" at comptime_allocator.zig:150:9
         result.bytes1 = (allocator.alloc(u32, 5) catch unreachable)[0..5];
         result.bytes2 = (allocator.alloc(u32, 10) catch unreachable)[0..10];
         break :blk result;
      };
   };
   testing.expectEqual(usize(5), S.foo.bytes1.len);
   testing.expectEqual(usize(10), S.foo.bytes2.len);
   testing.expectEqual(usize(5), S.foo.bytes1.len);
   testing.expectEqual(usize(10), S.foo.bytes2.len);
}

const Item = struct {
    integer: i32,
    sub_items: ArrayList(Item),
};

// fails to compile: "error: non-extern, non-packed struct 'Item' cannot have its bytes reinterpreted"
//test "std.ArrayList: ArrayList(T) of struct T (no known workaround)" {
//   const S = struct{fn doTheTest() !void {
//    var bytes: [1024]Item = undefined;
//    var allocator_object = TypedFixedBufferAllocator(Item).init(bytes[0..]);
//    var allocator = &allocator_object.allocator;
//    
//    var items = try allocator.realloc((([*]Item)(undefined))[0..0], 5);
//    
//    var root = Item{ .integer = 1, .sub_items = undefined};//ArrayList(Item).init(allocator) };
//    var ptr = &bytes[0];
    // assigning an Item object into bytes triggers "error: non-extern, non-packed struct 'Item' cannot have its bytes reinterpreted".
    // I assume the underlying memory is flagged as "being introspected" during comptime, even though we just use u8 to
    // pass it through and set it to undefined, and so using the array's "native" (original) type becomes prohibited.
//    ptr.* = root;
    //try root.sub_items.append(Item{ .integer = 42, .sub_items = ArrayList(Item).init(allocator) });
    //testing.expect(root.sub_items.items[0].integer == 42);
//   }};
//   try S.doTheTest();
//   comptime try S.doTheTest();
//}
