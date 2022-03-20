# Colloseum

This is a (very) WIP Zig implementation of the [generational arena](https://crates.io/crates/generational-arena) data structure. Thanks to generational indices, this becomes a safe arena allocator which allows deletion without suffering from the [ABA problem](https://en.wikipedia.org/wiki/ABA_problem).

## Why
Inspired by Andrew Kelley's [Practical Guide to Applying Data Oriented Design](https://media.handmade-seattle.com/practical-data-oriented-design/), I wanted to see how efficient a generational arena could be when using a structure of arrays approach. Zig makes this really easy by having a structure called "MultiArrayList" which breaks down a struct into... well a structure of arrays.

## Example
```zig
const Object = struct {
    a: usize,
    b: usize,
};

var arena = Arena(Object).init(allocator);

// Insert an object into the arena. This returns an Index object which
// Colosseum uses for retrieving and modifying objects inside itself
var index = arena.insert(.{
    .a = 1,
    .b = 2
});

// Get the inserted object based on it's index
var object = arena.get(index);

// Modify the object and save the modification
object.a = 4;
try arena.mutate(index, object);

// Delete the object from the arena. Once deleted, it's index value
// can never be used again
var deleted_object = arena.remove(index);
```