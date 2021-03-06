# Colloseum

This is a (very) WIP Zig implementation of the [generational arena](https://crates.io/crates/generational-arena) data structure. Thanks to generational indices, this becomes a safe arena allocator which allows deletion without suffering from the [ABA problem](https://en.wikipedia.org/wiki/ABA_problem).

## Why
Inspired by Andrew Kelley's [Practical Guide to Applying Data Oriented Design](https://media.handmade-seattle.com/practical-data-oriented-design/), I wanted to see how efficient a generational arena could be when using a structure of arrays approach. Zig makes this really easy by having a structure called "MultiArrayList" which breaks down a struct into... well a structure of arrays.

## Usage
Similar to a C stb header file, all one needs to do to use this library is copy the "colosseum.zig" file into their project. 

I might add support for gyro or zigmod if desired, but otherwise, I'll wait for the official zig package manager.

## Example
```zig
const Object = struct {
    a: usize,
    b: usize,
};

var arena = Arena(Object).init(allocator);

// Insert an object into the arena. This returns an Arena(Object).Index struct
// which Colosseum uses for retrieving and modifying objects inside itself
var index = try arena.append(.{
    .a = 1,
    .b = 2
});

// Get the inserted object based on it's index
// If the index doesn't exist, the value is null
var object = arena.get(index).?;

// Modify the object and save the modification
object.a = 4;
try arena.mutate(index, object);

// Delete the object from the arena. Once deleted, it's index value
// can never be used again
var deleted_object = arena.remove(index).?;

// Iterate through the arena
var iter = arena.iterator();
while (iter.next()) |_index| {
    var obj = arena.get(index).?;
    // Do something with object
    // Update the object if values were changed
    // The mutate error is unreachable since the iterated value must exist
    arena.mutate(_index, obj) catch unreachable;
}
```