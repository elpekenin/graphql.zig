const std = @import("std");
const StructField = std.builtin.Type.StructField;

fn err(comptime T: type) noreturn {
    @compileError("unsupported type: " ++ @typeName(T));
}

fn WrapReturn(comptime T: type, comptime flags: Flags(T)) type {
    switch (@typeInfo(T)) {
        .optional => |optional| return ?Subset(optional.child, flags),
        .pointer => |pointer| {
            if (pointer.size != .slice or !pointer.is_const or pointer.sentinel() != null) err(T);
            return []const Subset(pointer.child, flags);
        },
        .@"struct" => return Subset(T, flags),
        else => err(T),
    }
}

fn GetInner(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => unreachable,
        .optional => |optional| GetInner(optional.child),
        .pointer => |pointer| GetInner(pointer.child),
        .@"struct" => T,
        .vector => unreachable,
        else => T,
    };
}

const Visited = struct {
    types: []const type,

    fn init(comptime types: []const type) Visited {
        return .{ .types = types };
    }

    fn append(comptime self: *Visited, comptime T: type) void {
        if (!self.contains(T)) {
            self.types = self.types ++ &[_]type{T};
        }
    }

    fn contains(comptime self: Visited, comptime T: type) bool {
        return std.mem.indexOfScalar(type, self.types, T) != null;
    }
};

fn FlagsImpl(comptime visited: *Visited, T: type) type {
    const Inner = GetInner(T);

    // workaround for circular types
    if (visited.contains(Inner)) return void;
    visited.append(Inner);

    if (Inner == void) return void;

    const info = switch (@typeInfo(Inner)) {
        .@"struct" => |s| s,
        else => return bool,
    };

    var fields: []const StructField = &.{};
    for (info.fields) |field| {
        const FieldInner = GetInner(field.type);

        const FieldFlags = switch (@typeInfo(FieldInner)) {
            .@"struct" => FlagsImpl(visited, FieldInner),
            .void => continue,
            else => bool,
        };

        const default: FieldFlags = switch (FieldFlags) {
            bool => false,
            void => continue,
            else => .{},
        };

        fields = fields ++ &[_]StructField{
            .{
                .name = field.name,
                .type = FieldFlags,
                .default_value_ptr = &default,
                .is_comptime = false,
                .alignment = @alignOf(FieldFlags),
            },
        };
    }

    if (fields.len == 0) return void;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn Flags(comptime T: type) type {
    var visited: Visited = .init(&.{});
    return FlagsImpl(&visited, T);
}

// can't be `flags: Flags(T)` because it "expands" to `FlagsImpl(<visited>, T)`
// and 2 calls with different arrays and same T return different -yet compatible- types
fn Subset(comptime T: type, comptime flags: anytype) type {
    const struct_info = switch (@typeInfo(T)) {
        .optional => |optional| {
            const S = Subset(optional.child, flags);
            if (S == void) return void;
            return ?S;
        },
        .pointer => |pointer| {
            const S = Subset(pointer.child, flags);
            if (S == void) return void;
            return []const S;
        },
        .@"struct" => |s| s,
        else => return if (flags) T else void,
    };

    var fields: []const StructField = &.{};
    for (struct_info.fields) |field| {
        if (!@hasField(@TypeOf(flags), field.name)) continue;

        const flag = @field(flags, field.name);
        if (@TypeOf(flag) == void) continue;

        const new_field: StructField = switch (@typeInfo(field.type)) {
            .optional => |opt| blk: {
                const Child = Subset(opt.child, flag);
                if (Child == void) continue;

                const Optional = ?Child;
                const default: Optional = null;

                break :blk .{
                    .name = field.name,
                    .type = Optional,
                    .default_value_ptr = &default,
                    .is_comptime = false,
                    .alignment = @alignOf(Optional),
                };
            },

            .pointer => |pointer| blk: {
                if (!pointer.is_const or pointer.size != .slice or pointer.sentinel() != null) err(T);

                const Child = Subset(pointer.child, flag);
                if (Child == void) continue;

                const Slice = []const Child;
                const default: Slice = &.{};

                break :blk .{
                    .name = field.name,
                    .type = Slice,
                    .default_value_ptr = @ptrCast(&default),
                    .is_comptime = false,
                    .alignment = @alignOf(Slice),
                };
            },

            .@"struct" => blk: {
                const Child = Subset(field.type, flag);
                if (Child == void) continue;

                break :blk .{
                    .name = field.name,
                    .type = Child,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Child),
                };
            },

            .array,
            .vector,
            => err(T),

            .void => continue,

            else => if (flag) field else continue,
        };

        fields = fields ++ &[_]StructField{new_field};
    }

    if (fields.len == 0) return void;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

const GgraphQLError = struct {
    message: []const u8,
    locations: []const Location,
    path: []const []const u8,

    const Location = struct {
        line: usize,
        column: usize,
    };
};

const GraphQLErrors = struct {
    errors: []const GgraphQLError,
};

pub fn GraphQLResponse(comptime T: type, comptime operation: [:0]const u8, comptime fields: Flags(T)) type {
    const Out = WrapReturn(T, fields);

    const Data = @Type(.{
        .@"struct" = .{
            .decls = &.{},
            .fields = &.{
                .{
                    .name = operation,
                    .type = Out,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Out),
                },
            },
            .is_tuple = false,
            .layout = .auto,
        },
    });

    const Success = struct {
        data: Data,
    };

    return union(enum) {
        const Self = @This();

        ok: std.json.Parsed(Success),
        err: std.json.Parsed(GraphQLErrors),

        pub fn from(allocator: std.mem.Allocator, slice: []const u8) !Self {
            const options: std.json.ParseOptions = .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            };

            const data = std.json.parseFromSlice(Success, allocator, slice, options) catch |e| {
                std.log.err("cause: {}", .{e});
                std.log.info("{s}", .{slice});
                if (true) return e;

                const errors = try std.json.parseFromSlice(GraphQLErrors, allocator, slice, options);
                return .{ .err = errors };
            };

            return .{ .ok = data };
        }

        pub fn unwrap(self: Self) !Out {
            return switch (self) {
                .ok => |ok| @field(ok.value.data, operation),
                .err => error.UnwrapOnError,
            };
        }

        pub fn deinit(self: Self) void {
            switch (self) {
                .ok => |data| data.deinit(),
                .err => |errors| errors.deinit(),
            }
        }
    };
}

fn printType(comptime T: type) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => |t| {
            std.debug.print("{t}: {}", .{ t, T });
            return;
        },
    };

    std.debug.print("{{", .{});
    inline for (info.fields) |field| {
        std.debug.print(" {s}: ", .{field.name});
        printType(field.type);
        std.debug.print(",", .{});
    }
    std.debug.print("}}", .{});
}

const Error = error{FailTest};

fn expectEqlStructs(lhs: std.builtin.Type.Struct, rhs: std.builtin.Type.Struct) Error!void {
    if (lhs.is_tuple != rhs.is_tuple) return error.FailTest;
    if (lhs.fields.len != rhs.fields.len) return error.FailTest;

    inline for (0..lhs.fields.len) |i| {
        const lhs_field = lhs.fields[i];
        const rhs_field = rhs.fields[i];

        if (!std.mem.eql(u8, lhs_field.name, rhs_field.name)) return error.FailTest;

        if (lhs_field.type == rhs_field.type) continue;

        try expectEqlTypes(lhs_field.type, rhs_field.type);
    }
}

fn expectEqlUnions(lhs: std.builtin.Type.Union, rhs: std.builtin.Type.Union) Error!void {
    inline for (0..lhs.fields.len) |i| {
        const lhs_field = lhs.fields[i];
        const rhs_field = rhs.fields[i];

        if (!std.mem.eql(u8, lhs_field.name, rhs_field.name)) return error.FailTest;

        if (lhs_field.type == rhs_field.type) continue;

        try expectEqlTypes(lhs_field.type, rhs_field.type);
    }
}

fn expectEqlTypes(comptime LHS: type, comptime RHS: type) Error!void {
    if (LHS == RHS) return;

    const lhs = @typeInfo(LHS);
    const rhs = @typeInfo(RHS);
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return error.FailTest;

    switch (lhs) {
        .optional => return expectEqlTypes(lhs.optional.child, rhs.optional.child),
        .pointer => return expectEqlTypes(lhs.pointer.child, rhs.pointer.child),
        .@"struct" => return expectEqlStructs(lhs.@"struct", rhs.@"struct"),
        .@"union" => return expectEqlUnions(lhs.@"union", rhs.@"union"),

        else => {
            if (lhs != .@"struct" or rhs != .@"struct") {
                if (LHS != RHS) return error.FailTest;
            }
        },
    }
}

test expectEqlTypes {
    try expectEqlTypes(i1, i1);

    try std.testing.expectError(
        error.FailTest,
        expectEqlTypes(bool, u8),
    );

    try expectEqlTypes(
        struct { foo: struct { bool } },
        struct { foo: struct { bool } },
    );
}

test Flags {
    try expectEqlTypes(
        Flags(struct { foo: bool }),
        struct { foo: bool },
    );

    try expectEqlTypes(
        Flags(struct { foo: u8 }),
        struct { foo: bool },
    );

    try expectEqlTypes(
        Flags(struct { foo: ?u8 }),
        struct { foo: bool },
    );

    try expectEqlTypes(
        Flags(struct { foo: struct { bar: []u8 } }),
        struct { foo: struct { bar: bool } },
    );
}

test Subset {
    try expectEqlTypes(
        Subset(
            struct { foo: u8 },
            .{ .foo = true },
        ),
        struct { foo: u8 },
    );

    try expectEqlTypes(
        Subset(
            struct { foo: u8 },
            .{ .foo = false },
        ),
        void,
    );

    try expectEqlTypes(
        Subset(
            struct { foo: struct { bar: usize, baz: bool } },
            .{ .foo = .{ .bar = true } },
        ),
        struct { foo: struct { bar: usize } },
    );

    try expectEqlTypes(
        Subset(
            struct {
                foo: []const struct {
                    bar: u8,
                    baz: u16,
                },
                bar: u32,
            },
            .{ .foo = .{ .bar = true } },
        ),
        struct { foo: []const struct { bar: u8 } },
    );

    try expectEqlTypes(
        Subset(
            struct {
                foo: []const struct {
                    bar: u8,
                    baz: u16,
                },
                bar: u32,
            },
            .{ .bar = true },
        ),
        struct { bar: u32 },
    );
}

test GraphQLResponse {
    const R = struct { foo: u8 };

    try expectEqlTypes(
        GraphQLResponse(R, "name", .{ .foo = true }),
        union(enum) {
            ok: std.json.Parsed(struct { data: struct { name: R } }),
            err: std.json.Parsed(GraphQLErrors),
        },
    );
}
