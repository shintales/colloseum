const std = @import("std");
const testing = std.testing;

/// The `Arena` allows appending and removing elements that are referred to by
/// `Index`.
const DEFAULT_CAPACITY: usize = 4;

pub const Error = error{ MutateOnEmptyEntry };

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

pub fn Arena(comptime Entry: type) type {
    return struct {
        const Self = @This();
        const EntryList = std.MultiArrayList(Entry);
        const StatusList = std.ArrayListUnmanaged(EntryStatus);

        allocator: std.mem.Allocator,
        entries: EntryList,
        statuses: StatusList,
        free_list_head: ?usize,
        len: usize,

        pub fn init(allocator: std.mem.Allocator) Self {
            return withCapacity(allocator, DEFAULT_CAPACITY);
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.statuses.deinit(self.allocator);
        }

        /// Create an arena with an initial capacity
        fn withCapacity(allocator: std.mem.Allocator, _capacity: usize) Self {
            var arena = Self{
                .allocator = allocator,
                .entries = EntryList{},
                .statuses = StatusList{},
                .free_list_head = null,
                .len = 0,
            };
            arena.reserve(_capacity) catch unreachable;
            return arena;
        }

        /// Get the current capacity of the arena
        pub fn capacity(self: *const Self) usize {
            return self.statuses.items.len;
        }

        /// Allocate space for a new entry
        fn alloc(self: *Self) ?Index {
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
                return null;
            }
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        pub fn append(self: *Self, item: Entry) !Index {
            return if (self.appendQuick(item)) |index| {
                    return index;
                } else {
                    return self.appendSlow(item) catch |err| return err;
                };
        }

        fn appendQuick(self: *Self, value: Entry) ?Index {
            if (self.alloc()) |index| {
                self.entries.set(index.index, value);
                self.statuses.items[index.index] = EntryStatus.Occupied(index);
                return index;
            } else return null;
        }

        fn appendSlow(self: *Self, value: Entry) !Index {
            var len = self.entries.len;
            try self.reserve(len);
            // Since the reserve would have succeeded, appendQuick would not have to
            // output a null value
            return self.appendQuick(value).?;
        }

        /// Mark all entries as empty and invalidate their data
        pub fn clear(self: *Self) void {
            self.entries.shrinkRetainingCapacity(0);
            self.statuses.clearRetainingCapacity();
            self.statuses.expandToCapacity();
            self.entries.setCapacity(self.allocator, self.statuses.capacity) catch unreachable;

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

        /// Allocate space for `additional_capacity` more elements in the arena.
        pub fn reserve(self: *Self, additional_capacity: usize) !void {
            var start = self.statuses.items.len;
            var end = start + additional_capacity;
            var old_list_head = self.free_list_head;
            try self.entries.resize(self.allocator, end);
            try self.statuses.resize(self.allocator, end);

            for (self.statuses.items[start..end]) |*status, unpadded_i| {
                const i = unpadded_i + start;
                if (i == (end - 1)) {
                    status.* = EntryStatus.Empty(old_list_head, 0);
                } else {               
                    status.* = EntryStatus.Empty(i + 1, 0);
                }
            }
            
            self.free_list_head = start;  
        }
    };
}

const RigidBody = struct {
    position: usize,
    velocity: usize,

    fn default() RigidBody {
        return .{
            .position = 0,
            .velocity = 0,
        };
    }
};

test "Arena.alloc" {
    var allocator = std.testing.allocator;
    var arena = Arena(RigidBody).init(allocator);
    defer arena.deinit();

    var i = arena.alloc().?;
    try std.testing.expectEqual(i.index, 0);
    try std.testing.expectEqual(i.generation, 0);
}

test "Arena.append" {
    var allocator = std.testing.allocator;
    var arena = Arena(RigidBody).init(allocator);
    defer arena.deinit();

    var rb = RigidBody.default();
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(index, Index.fromParts(i, 0));
        try std.testing.expectEqual(arena.get(index).?, rb);
    }
}

test "Arena.remove" {
    var allocator = std.testing.allocator;
    var arena = Arena(RigidBody).init(allocator);
    defer arena.deinit();

    var rb = RigidBody.default();
    var i: usize = 0;
    try std.testing.expectEqual(@as(usize,4), arena.capacity());
    
    while (i < 4) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(arena.get(index).?, rb);
        try std.testing.expectEqual(index, Index.fromParts(i, 0));
    }
    try std.testing.expectEqual(@as(usize,4), arena.capacity());
    
    while (i < 4) : (i += 1) {
        const index = Index.fromParts(i, 0);
        var before_delete = arena.get(index).?;
        var deleted_entry = arena.remove(index).?;
        try std.testing.expect(!arena.contains(index));
        try std.testing.expectEqual(before_delete, deleted_entry);
    }
    try std.testing.expectEqual(@as(usize,4), arena.capacity());
    
    while (i < 4) : (i += 1) {
        var index = try arena.append(rb);
        try std.testing.expectEqual(arena.get(index).?, rb);
        try std.testing.expectEqual(index, Index.fromParts(i, 1));
    }
    try std.testing.expectEqual(@as(usize,4), arena.capacity());
}

test "Arena.clear" {
    var allocator = std.testing.allocator;
    var arena = Arena(RigidBody).init(allocator);
    defer arena.deinit();

    var index1 = try arena.append(RigidBody.default());
    var index2 = try arena.append(RigidBody.default());
    var index3 = try arena.append(RigidBody.default());
    arena.clear();
    try std.testing.expect(!arena.contains(index1));
    try std.testing.expect(!arena.contains(index2));
    try std.testing.expect(!arena.contains(index3));
}

test "Arena.mutate" {
    var allocator = std.testing.allocator;
    var arena = Arena(RigidBody).init(allocator);
    defer arena.deinit();

    var index = try arena.append(RigidBody.default());
    var rb = arena.get(index).?;
    rb.position = 1;
    rb.velocity = 1;
    try arena.mutate(index, rb);
    try std.testing.expectEqual(arena.get(index).?, rb);
}
