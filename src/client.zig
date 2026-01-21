const std = @import("std");
const Allocator = std.mem.Allocator;

const requezt = @import("requezt");

const meta = @import("meta.zig");

fn hasData(comptime T: type, value: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var has_data = false;

            inline for (info.fields) |field| {
                if (hasData(field.type, @field(value, field.name))) {
                    has_data = true;
                }
            }

            return has_data;
        },
        .optional => return value != null,
        else => return true,
    }
}

fn writeArg(comptime T: type, writer: *std.Io.Writer, name: ?[]const u8, value: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (name) |n| try writer.print("{s}:{{", .{n});

            inline for (info.fields) |field| {
                const field_value = @field(value, field.name);
                try writeArg(field.type, writer, field.name, field_value);
            }

            if (name != null) try writer.print("}},", .{});
        },
        .optional => |optional| {
            const unwrapped = value orelse return;
            try writeArg(optional.child, writer, name, unwrapped);
        },
        .int => try writer.print("{s}:{},", .{ name.?, value }),
        else => switch (T) {
            []const u8 => try writer.print("{s}:\"{s}\",", .{ name.?, value }),
            else => @compileError("unsupported type " ++ @typeName(T)),
        },
    }
}

fn printFields(comptime T: type, writer: *std.Io.Writer, name: ?[]const u8, value: T) !bool {
    var bracket_printed = false;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_value = @field(value, field.name);

        switch (@typeInfo(field.type)) {
            .@"struct" => {
                if (try printFields(field.type, writer, field.name, field_value)) {
                    try writer.print(", ", .{});
                    bracket_printed = true;
                }
            },
            .bool => {
                if (field_value) {
                    if (!bracket_printed) {
                        if (name) |n| try writer.print("{s} ", .{n});
                        try writer.print("{{", .{});
                        bracket_printed = true;
                    }

                    try writer.print(" {s},", .{field.name});
                }
            },
            else => @compileError("unsupported type: " ++ @typeName(field.type)),
        }
    }

    if (bracket_printed) try writer.print("}}", .{});

    return bracket_printed;
}

pub fn Client(comptime url: []const u8, comptime schema: type) type {
    return struct {
        pub fn execute(
            allocator: Allocator,
            comptime operation: [:0]const u8,
            args: @field(schema.Query, operation).Args,
            comptime fields: meta.Flags(@field(schema.Query, operation).Return),
        ) !meta.GraphQLResponse(@field(schema.Query, operation).Return, operation, fields) {
            var client: requezt.Client = .init(allocator, .{});
            defer client.deinit();

            var allocating: std.Io.Writer.Allocating = .init(allocator);
            defer allocating.deinit();
            const writer = &allocating.writer;

            try writer.print("query{{{s}", .{operation});

            const has_args = hasData(@TypeOf(args), args);
            if (has_args) {
                try writer.print("(", .{});
                try writeArg(@TypeOf(args), writer, null, args);
                try writer.print(")", .{});
            }

            _ = try printFields(@TypeOf(fields), writer, null, fields);

            try writer.print("}}", .{});

            const query = try allocating.toOwnedSlice();
            defer allocator.free(query);

            var response = try client.postJson(
                url,
                .{
                    .query = query,
                    // .variables = args,
                },
                .{
                    .headers = .{
                        .content_type = "application/json",
                    },
                },
            );
            defer response.deinit();

            return .from(allocator, response.body_data);
        }
    };
}
