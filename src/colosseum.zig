const std = @import("std");
const testing = std.testing;

/// The `Arena` allows appending and removing elements that are referred to by
/// `Arena(T).Index`.
const DEFAULT_CAPACITY: usize = 4;

pub const Error = error{ MutateOnEmptyEntry };

pub fn Arena(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        unmanaged: Unmanaged,

        const Unmanaged = ArenaUnmanaged(T);

        pub const Index = Unmanaged.Index;
        pub const Entry = Unmanaged.Entry;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .unmanaged = Unmanaged{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }

        pub fn capacity(self: *const Self) usize {
            return self.unmanaged.capacity();
        }

        pub fn append(self: *Self, item: T) !Index {
            return self.unmanaged.append(self.allocator, item);
        }

        pub fn clear(self: *Self) void {
            self.unmanaged.clear(self.allocator);
        }

        pub fn remove(self: *Self, i: Index) ?Entry {
            return self.unmanaged.remove(i);
        }

        /// Check if an index exists in the arena 
        pub fn contains(self: *Self, i: Index) bool {
            return self.unmanaged.contains(i);
        }

        pub fn get(self: *Self, i: Index) ?Entry {
            return self.unmanaged.get(i);
        }

        /// Overwrite one arena element with new data.
        pub fn mutate(self: *Self, i: Index, entry: Entry) !void {
            self.unmanaged.mutate(i,entry) catch |err| return err;
        }

        /// Check if the arena is empty
        pub fn isEmpty(self: *Self) bool {
            return self.unmanaged.isEmpty();
        }

        pub const Iterator = Unmanaged.Iterator;

        pub fn iterator(self: *Self) Iterator {
            return self.unmanaged.iterator();
        }
    };
}

pub fn ArenaUnmanaged(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Index = struct {
            index: usize,
            generation: usize,

            pub fn fromParts(index: usize, generation: usize) Index {
                return .{ .index = index, .generation = generation };
            }

            pub fn equals(a: Index, b: Index) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const EmptyEntry = struct {
            next_free: ?usize,
            generation: usize,
        };

        const EntryStatus = union(enum) {
            occupied: Index,
            empty: EmptyEntry,

            fn Occupied(i: Index) EntryStatus {
                return .{ .occupied = i };
            }

            fn Empty(next_free: ?usize, generation: usize) EntryStatus {
                return .{ .empty = EmptyEntry{ .next_free = next_free, .generation = generation } };
            }
        };


        pub const Entry = T;
        const EntryList = std.MultiArrayList(Entry);
        const StatusList = std.ArrayListUnmanaged(EntryStatus);

        entries: EntryList = .{},
        statuses: StatusList = .{},
        free_list_head: ?usize = null,
        len: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.statuses.deinit(allocator);
        }

        /// Get the current capacity of the arena
        pub fn capacity(self: *const Self) usize {
            return self.statuses.items.len;
        }

        /// Allocate space for a new entry
        fn alloc(self: *Self, allocator: std.mem.Allocator) !Index {
            if (self.free_list_head) |i| {
                switch (self.statuses.items[i]) {
                    .occupied => {
                        @panic("Corrupted free list");
                    },
                    .empty => |value| {
                        self.free_list_head = value.next_free;
                        self.len += 1;
                        return Index.fromParts(i, value.generation);
                    },
                }
            } else {
                var i = self.statuses.items.len;
                try self.statuses.append(allocator, EntryStatus.Empty(i, 0));
                try self.entries.resize(allocator, self.statuses.capacity);
                self.len += 1;
                return Index.fromParts(i, 0);
            }
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        pub fn append(self: *Self, allocator: std.mem.Allocator, item: T) !Index {
            var index = try self.alloc(allocator);
            self.entries.set(index.index, item);
            self.statuses.items[index.index] = EntryStatus.Occupied(index);
            return index;
        }

        /// Mark all entries as empty and invalidate their data
        pub fn clear(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.shrinkRetainingCapacity(0);
            self.statuses.clearRetainingCapacity();
            self.statuses.expandToCapacity();
            self.entries.setCapacity(allocator, self.statuses.capacity) catch unreachable;

            var end = self.statuses.capacity;
            for (self.statuses.items) |*status, i| {
                const generation = switch (status.*) {
                    .occupied => |value| value.generation + 1,
                    .empty => |value| value.generation,
                };
                if (i == end - 1) {
                    status.* = EntryStatus.Empty(null, generation);
                } else {
                    status.* = EntryStatus.Empty(i + 1, generation);
                }
            }

            self.free_list_head = 0;
            self.len = 0;
        }

        /// Removes the element at the specified index and returns it
        /// if it exists. Otherwise returns null.
        /// This operation is O(1).
        pub fn remove(self: *Self, i: Index) ?Entry {
            if (i.index >= self.len) {
                return null;
            }
            var entry_to_delete = self.statuses.items[i.index];
            return switch (entry_to_delete) {
                .occupied => |occupant| if (occupant.equals(i)) {
                    const new_generation = occupant.generation + 1;
                    self.statuses.items[i.index] = EntryStatus.Empty(i.index, new_generation);
                    self.free_list_head = i.index;
                    self.len -= 1;
                    return self.entries.get(i.index);
                } else return null,
                else => null,
            };
        }

        /// Check if an index exists in the arena 
        pub fn contains(self: *Self, i: Index) bool {
            return switch (self.statuses.items[i.index]) {
                .occupied => |occupant| occupant.equals(i),
                else => false,
            };
        }

        /// Obtain all the data for one entry in the arena.
        pub fn get(self: *Self, i: Index) ?Entry {
            return switch (self.statuses.items[i.index]) {
                .occupied => if (self.contains(i)) self.entries.get(i.index) else null,
                else => null,
            };
        }

        /// Overwrite one arena element with new data.
        pub fn mutate(self: *Self, i: Index, entry: Entry) !void {
            return switch (self.statuses.items[i.index]) {
                .occupied => self.entries.set(i.index, entry),
                else => return Error.MutateOnEmptyEntry,
            };
        }

        /// Check if the arena is empty
        pub inline fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        pub const Iterator = struct {
            ctx: *Self,
            pos: usize = 0,

            pub fn next(self: *Iterator) ?Index {
                if ((self.pos) >= self.ctx.len) return null;
                return switch(self.ctx.statuses.items[self.pos]) {
                    .empty => {
                        self.pos += 1;
                        return self.next();
                    },
                    .occupied => |occupant| {
                        self.pos += 1;
                        return occupant;
                    } 
                };
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Self.Iterator{ .ctx = self };
        }
    };
}

const Example = struct {
    a: usize,
    b: usize,

    fn default() Example {
        return .{
            .a = 0,
            .b = 0,
        };
    }
};

const ExampleArena = Arena(Example);
const ExampleArenaUnmanaged = ArenaUnmanaged(Example);
const ExampleArenaIndex = ExampleArena.Index;

test "Arena.alloc" {
    var allocator = std.testing.allocator;
    var arena = ExampleArenaUnmanaged{};
    defer arena.deinit(allocator);
    
    var i = try arena.alloc(allocator);
    try std.testing.expectEqual(i.index, 0);
    try std.testing.expectEqual(i.generation, 0);
}

test "Arena.append" {
    var allocator = std.testing.allocator;
    var arena = ExampleArena.init(allocator);
    defer arena.deinit();

    var rb = Example.default();
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(index, ExampleArenaIndex.fromParts(i, 0));
        try std.testing.expectEqual(arena.get(index).?, rb);
    }
}

test "Arena.remove" {
    var allocator = std.testing.allocator;
    var arena = ExampleArena.init(allocator);
    defer arena.deinit();

    var rb = Example.default();
    var i: usize = 0;
    
    while (i < 4) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(arena.get(index).?, rb);
        try std.testing.expectEqual(index, ExampleArenaIndex.fromParts(i, 0));
    }
    
    while (i < 4) : (i += 1) {
        const index = ExampleArenaIndex.fromParts(i, 0);
        var before_delete = arena.get(index).?;
        var deleted_entry = arena.remove(index).?;
        try std.testing.expect(!arena.contains(index));
        try std.testing.expectEqual(before_delete, deleted_entry);
    }
    
    while (i < 4) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(arena.get(index).?, rb);
        try std.testing.expectEqual(index, ExampleArenaIndex.fromParts(i, 1));
    }
}

test "Arena.clear" {
    var allocator = std.testing.allocator;
    var arena = ExampleArena.init(allocator);
    defer arena.deinit();

    var index1 = try arena.append(Example.default());
    var index2 = try arena.append(Example.default());
    var index3 = try arena.append(Example.default());
    arena.clear();
    try std.testing.expect(!arena.contains(index1));
    try std.testing.expect(!arena.contains(index2));
    try std.testing.expect(!arena.contains(index3));
}

test "Arena.mutate" {
    var allocator = std.testing.allocator;
    var arena = ExampleArena.init(allocator);
    defer arena.deinit();

    var index = try arena.append(Example.default());
    var rb = arena.get(index).?;
    rb.a = 1;
    rb.b = 1;
    try arena.mutate(index, rb);
    try std.testing.expectEqual(arena.get(index).?, rb);
}

test "Arena.iterator" {
    var allocator = std.testing.allocator;
    var arena = ExampleArena.init(allocator);
    defer arena.deinit();

    var rb = Example.default();
    _ = try arena.append(rb);
    var delete_index = try arena.append(rb);
    _ = arena.remove(delete_index);
    delete_index = try arena.append(rb);
    _ = arena.remove(delete_index);
    _ = try arena.append(rb);

    var iter = arena.iterator();
    var counter: usize = 0;
    while (iter.next()) |_| {
        counter += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), counter);
}