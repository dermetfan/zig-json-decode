const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const json_key_prefix = "json_";

pub const dump = @import("json_dump.zig").dump;

pub const DecodeOptions = struct {
    ignoreMissing: bool = false,
};

fn fieldCount(comptime T: type) usize {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Struct) @compileError("Attempted to call fieldCount() on a non struct");
    comptime var count = 0;
    inline for (typeInfo.Struct.fields) |field| {
        if (!mem.startsWith(u8, field.name, json_key_prefix)) {
            count += 1;
        }
    }
    return count;
}

pub fn Decodable(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .Struct) @compileError("Attempted to call Decodable() on a non struct (" ++ @typeName(T) ++ ")");
    return struct {
        const Self = @This();

        const Error = mem.Allocator.Error || error{MissingField};

        pub fn fromJson(options: DecodeOptions, allocator: *mem.Allocator, node: var) Error!T {
            var item: *T = try allocator.create(T);
            if (info != .Struct) unreachable;
            // hot path for missing
            if (!options.ignoreMissing and fieldCount(T) != node.count()) return error.MissingField;
            inline for (info.Struct.fields) |field| {
                const maybeJsonMapping = json_key_prefix ++ field.name;
                const fieldName = field.name;
                const accessorKey = if (@hasDecl(T, maybeJsonMapping)) @field(T, maybeJsonMapping) else field.name;
                const fieldTypeInfo = @typeInfo(field.field_type);
                if (node.get(accessorKey)) |obj| {
                    if (fieldTypeInfo == .Struct) { // complex json type
                        const generatedType = Decodable(field.field_type);
                        @field(item, fieldName) = try generatedType.fromJson(options, allocator, obj.value.Object);
                    } else if (fieldTypeInfo == .Pointer and field.field_type != []const u8) { // strings are handled
                        const arrayType = fieldTypeInfo.Pointer.child;
                        const values = obj.value.Array;
                        var dest = try allocator.alloc(arrayType, values.toSliceConst().len);
                        if (comptime isNativeJSONType(arrayType)) {
                            for (values.toSliceConst()) |value, index| {
                                dest[index] = switch (arrayType) {
                                    i64 => value.Integer,
                                    f64 => value.Float,
                                    bool => value.Bool,
                                    []const u8 => value.String,
                                    else => unreachable,
                                };
                            }
                        } else {
                            const generatedArrayType = Decodable(arrayType);
                            for (values.toSliceConst()) |value, index| {
                                dest[index] = try generatedArrayType.fromJson(options, allocator, value.Object);
                            }
                        }
                        @field(item, fieldName) = dest;
                    } else if (fieldTypeInfo == .Optional) {
                        if (obj.value == .Null) {
                            @field(item, fieldName) = null;
                        } else {
                            const childType = fieldTypeInfo.Optional.child;
                            assignRawType(item, fieldName, childType, obj);
                        }
                    } else {
                        assignRawType(item, fieldName, field.field_type, obj);
                    }
                } else if (!options.ignoreMissing) return error.MissingField;
            }
            return item.*;
        }
    };
}

fn isNativeJSONType(comptime T: type) bool {
    return switch (T) {
        i64, f64, []const u8, bool => true,
        else => false,
    };
}

fn assignRawType(destination: var, comptime fieldName: []const u8, comptime fieldType: type, object: var) void {
    switch (fieldType) {
        i64 => @field(destination, fieldName) = object.value.Integer,
        f64 => @field(destination, fieldName) = object.value.Float,
        bool => @field(destination, fieldName) = object.value.Bool,
        []const u8 => @field(destination, fieldName) = object.value.String,
        else => @compileError(@typeName(fieldType) ++ " is not supported"),
    }
}

const TestSkeleton = struct {
    int: i64,
    isCool: bool,
    float: f64,
    language: []const u8,
    optional: ?bool,
    array: []f64,

    const Bar = struct {
        nested: []const u8,
    };
    complex: Bar,

    const Baz = struct {
        foo: []const u8,
    };
    veryComplex: []Baz,
};
const TestStruct = Decodable(TestSkeleton);

test "JSON Mapping works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse("{\"TEST_EXPECTED\": 1}");
    const S = Decodable(struct {
        expected: i64,
        pub const json_expected: []const u8 = "TEST_EXPECTED";
    });
    const s = try S.fromJson(.{}, allocator, tree.root.Object);
}

test "NoIgnore works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse("{}");
    const S = Decodable(struct {
        expected: i64,
    });
    const attempt = S.fromJson(.{}, allocator, tree.root.Object);
    std.testing.expectError(error.MissingField, attempt);
}

test "Decode works" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const json =
        \\{
        \\  "int": 420,
        \\  "float": 3.14,
        \\  "isCool": true,
        \\  "language": "zig",
        \\  "optional": null,
        \\  "array": [66.6, 420.420, 69.69],
        \\  "complex": {
        \\    "nested": "zig"
        \\  },
        \\  "veryComplex": [
        \\    {
        \\      "foo": "zig"
        \\    }, {
        \\      "foo": "rocks"
        \\    }
        \\  ]
        \\}
    ;
    var p = std.json.Parser.init(allocator, false);
    defer p.deinit();
    const tree = try p.parse(json);
    const testStruct = try TestStruct.fromJson(.{}, allocator, tree.root.Object);
    testing.expectEqual(testStruct.int, 420);
    testing.expectEqual(testStruct.float, 3.14);
    testing.expectEqual(testStruct.isCool, true);
    testing.expect(mem.eql(u8, testStruct.language, "zig"));
    testing.expectEqual(testStruct.optional, null);
    testing.expect(mem.eql(u8, testStruct.complex.nested, "zig"));
    testing.expectEqual(testStruct.array[0], 66.6);
    testing.expectEqual(testStruct.array[1], 420.420);
    testing.expectEqual(testStruct.array[2], 69.69);
    testing.expect(mem.eql(u8, testStruct.veryComplex[0].foo, "zig"));
    testing.expect(mem.eql(u8, testStruct.veryComplex[1].foo, "rocks"));
}
