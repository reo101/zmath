const std = @import("std");

pub fn isContainerType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return isContainerType(T) and @hasDecl(T, name);
}

pub fn hasDecls(comptime T: type, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (!hasDecl(T, name)) return false;
    }
    return true;
}

pub fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn hasFields(comptime T: type, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (!hasField(T, name)) return false;
    }
    return true;
}

pub fn hasDeclType(comptime T: type, comptime name: []const u8, comptime Expected: type) bool {
    return hasDecl(T, name) and isType(@TypeOf(@field(T, name)), Expected);
}

pub fn hasDeclTypeOneOf(comptime T: type, comptime name: []const u8, comptime Expected: []const type) bool {
    if (!hasDecl(T, name)) return false;

    return isTypeOneOf(@TypeOf(@field(T, name)), Expected);
}

pub fn hasFieldType(comptime T: type, comptime name: []const u8, comptime Expected: type) bool {
    return switch (@typeInfo(T)) {
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break :blk isType(field.type, Expected);
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn isType(comptime Actual: type, comptime Expected: type) bool {
    return Actual == Expected;
}

pub fn isTypeOneOf(comptime Actual: type, comptime Expected: []const type) bool {
    inline for (Expected) |Allowed| {
        if (Actual == Allowed) return true;
    }
    return false;
}

pub fn isErrorSetType(comptime T: type) bool {
    return @typeInfo(T) == .error_set;
}

fn fieldType(comptime T: type, comptime name: []const u8) type {
    return switch (@typeInfo(T)) {
        inline .@"struct", .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break :blk field.type;
            }
            unreachable;
        },
        else => unreachable,
    };
}

fn invalidTypePrefix(comptime T: type, comptime role: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "type {s} is not a valid {s}: ",
        .{ @typeName(T), role },
    );
}

fn formatTypeOptions(comptime Expected: []const type) []const u8 {
    if (Expected.len == 0) return "";
    if (Expected.len == 1) return std.fmt.comptimePrint("`{s}`", .{@typeName(Expected[0])});

    var message = "";
    inline for (Expected, 0..) |Allowed, index| {
        const separator = if (index == 0) "" else if (index + 1 == Expected.len) " or " else ", ";
        message = message ++ separator ++ std.fmt.comptimePrint("`{s}`", .{@typeName(Allowed)});
    }
    return message;
}

pub const DeclLookupOptions = struct {
    owner: []const u8,
    decl_role: []const u8 = "declaration",
    invalid_prefix: ?[]const u8 = null,

    fn invalidPrefix(self: @This()) []const u8 {
        return self.invalid_prefix orelse std.fmt.comptimePrint(
            "{s} must declare ",
            .{self.owner},
        );
    }
};

fn missingDeclMessage(comptime name: []const u8, comptime options: DeclLookupOptions) []const u8 {
    return std.fmt.comptimePrint(
        "{s} is missing required {s} `{s}`",
        .{ options.owner, options.decl_role, name },
    );
}

pub fn requireNamedType(
    comptime prefix: []const u8,
    comptime name: []const u8,
    comptime Actual: type,
    comptime Expected: type,
) void {
    if (!isType(Actual, Expected)) {
        @compileError(prefix ++ std.fmt.comptimePrint(
            "`{s}` must be `{s}`",
            .{ name, @typeName(Expected) },
        ));
    }
}

pub fn requireNamedTypeSatisfies(
    comptime prefix: []const u8,
    comptime name: []const u8,
    comptime Actual: type,
    comptime predicate: fn (type) bool,
    comptime expectation: []const u8,
) void {
    if (!predicate(Actual)) {
        @compileError(prefix ++ std.fmt.comptimePrint(
            "`{s}` must be {s}",
            .{ name, expectation },
        ));
    }
}

pub fn requireNamedTypeOneOf(
    comptime prefix: []const u8,
    comptime name: []const u8,
    comptime Actual: type,
    comptime Expected: []const type,
) void {
    if (!isTypeOneOf(Actual, Expected)) {
        @compileError(prefix ++ std.fmt.comptimePrint(
            "`{s}` must be one of {s}",
            .{ name, formatTypeOptions(Expected) },
        ));
    }
}

fn lookupDeclTypeOrError(
    comptime lookup: fn (comptime []const u8) ?type,
    comptime name: []const u8,
    comptime options: DeclLookupOptions,
) type {
    return lookup(name) orelse @compileError(missingDeclMessage(name, options));
}

pub fn requireLookupDecl(
    comptime lookup: fn (comptime []const u8) ?type,
    comptime name: []const u8,
    comptime options: DeclLookupOptions,
) void {
    _ = lookupDeclTypeOrError(lookup, name, options);
}

pub fn requireLookupDeclType(
    comptime lookup: fn (comptime []const u8) ?type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime options: DeclLookupOptions,
) void {
    requireNamedType(
        options.invalidPrefix(),
        name,
        lookupDeclTypeOrError(lookup, name, options),
        Expected,
    );
}

pub fn requireLookupDeclTypeOneOf(
    comptime lookup: fn (comptime []const u8) ?type,
    comptime name: []const u8,
    comptime Expected: []const type,
    comptime options: DeclLookupOptions,
) void {
    requireNamedTypeOneOf(
        options.invalidPrefix(),
        name,
        lookupDeclTypeOrError(lookup, name, options),
        Expected,
    );
}

pub fn requireLookupDeclSatisfies(
    comptime lookup: fn (comptime []const u8) ?type,
    comptime name: []const u8,
    comptime predicate: fn (type) bool,
    comptime expectation: []const u8,
    comptime options: DeclLookupOptions,
) void {
    requireNamedTypeSatisfies(
        options.invalidPrefix(),
        name,
        lookupDeclTypeOrError(lookup, name, options),
        predicate,
        expectation,
    );
}

pub fn requireDecl(
    comptime T: type,
    comptime name: []const u8,
    comptime role: []const u8,
    comptime decl_role: []const u8,
) void {
    if (!@hasDecl(T, name)) {
        @compileError(invalidTypePrefix(T, role) ++ std.fmt.comptimePrint(
            "missing {s} `{s}`",
            .{ decl_role, name },
        ));
    }
}

pub fn requireDecls(
    comptime T: type,
    comptime names: []const []const u8,
    comptime role: []const u8,
    comptime decl_role: []const u8,
) void {
    inline for (names) |name| {
        requireDecl(T, name, role, decl_role);
    }
}

pub fn requireField(
    comptime T: type,
    comptime name: []const u8,
    comptime role: []const u8,
) void {
    if (!hasField(T, name)) {
        @compileError(invalidTypePrefix(T, role) ++ std.fmt.comptimePrint(
            "missing field `{s}`",
            .{name},
        ));
    }
}

pub fn requireFields(
    comptime T: type,
    comptime names: []const []const u8,
    comptime role: []const u8,
) void {
    inline for (names) |name| {
        requireField(T, name, role);
    }
}

pub fn requireDeclType(
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime role: []const u8,
    comptime decl_role: []const u8,
) void {
    requireDecl(T, name, role, decl_role);
    requireNamedType(
        invalidTypePrefix(T, role),
        name,
        @TypeOf(@field(T, name)),
        Expected,
    );
}

pub fn requireDeclTypeOneOf(
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: []const type,
    comptime role: []const u8,
    comptime decl_role: []const u8,
) void {
    requireDecl(T, name, role, decl_role);
    requireNamedTypeOneOf(
        invalidTypePrefix(T, role),
        name,
        @TypeOf(@field(T, name)),
        Expected,
    );
}

pub fn requireFieldType(
    comptime T: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime role: []const u8,
) void {
    requireField(T, name, role);
    requireNamedType(
        invalidTypePrefix(T, role) ++ "field ",
        name,
        fieldType(T, name),
        Expected,
    );
}

test "meta helpers report declaration and field presence" {
    const Example = struct {
        pub const answer = 42;
        field: u8,
    };

    try std.testing.expect(hasDecl(Example, "answer"));
    try std.testing.expect(hasDecls(Example, &.{"answer"}));
    try std.testing.expect(hasField(Example, "field"));
    try std.testing.expect(hasFields(Example, &.{"field"}));
    try std.testing.expect(hasDeclType(Example, "answer", comptime_int));
    try std.testing.expect(hasFieldType(Example, "field", u8));
}

test "meta helpers support multiple allowed declaration types" {
    const Example = struct {
        pub fn byValue(_: @This()) void {}
    };

    try std.testing.expect(hasDeclTypeOneOf(Example, "byValue", &.{
        fn (Example) void,
        fn (*const Example) void,
    }));
}

test "meta helpers support direct type checks" {
    try std.testing.expect(isType(u8, u8));
    try std.testing.expect(isTypeOneOf(u8, &.{ u16, u8 }));
}
