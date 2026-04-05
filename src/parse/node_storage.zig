const std = @import("std");
const meta = @import("../meta.zig");

pub fn Fixed(
    comptime Node: type,
    comptime NodeInfo: type,
    comptime max_nodes: usize,
    comptime max_placeholders: usize,
) type {
    return struct {
        const Self = @This();
        pub const StorageError = error{ExpressionTooLarge};

        pub const Compiled = struct {
            nodes: [max_nodes]Node,
            node_count: usize,
            root: usize,
            placeholder_names: [max_placeholders][]const u8,
            placeholder_count: usize,
        };

        nodes: [max_nodes]Node = undefined,
        infos: [max_nodes]NodeInfo = undefined,
        node_count: usize = 0,
        placeholder_names: [max_placeholders][]const u8 = undefined,
        placeholder_count: usize = 0,

        pub fn deinit(_: *Self) void {}

        pub fn newNode(self: *Self, node: Node, info: NodeInfo) StorageError!usize {
            if (self.node_count >= max_nodes) return error.ExpressionTooLarge;
            const index = self.node_count;
            self.nodes[index] = node;
            self.infos[index] = info;
            self.node_count += 1;
            return index;
        }

        pub fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.infos[index];
        }

        pub fn nodeAt(self: Self, index: usize) Node {
            return self.nodes[index];
        }

        pub fn placeholderNames(self: Self) []const []const u8 {
            return self.placeholder_names[0..self.placeholder_count];
        }

        pub fn appendPlaceholder(self: *Self, name: []const u8) StorageError!usize {
            if (self.placeholder_count >= max_placeholders) return error.ExpressionTooLarge;
            const slot = self.placeholder_count;
            self.placeholder_names[slot] = name;
            self.placeholder_count += 1;
            return slot;
        }

        pub fn finish(self: *Self, root: usize) StorageError!Compiled {
            return .{
                .nodes = self.nodes,
                .node_count = self.node_count,
                .root = root,
                .placeholder_names = self.placeholder_names,
                .placeholder_count = self.placeholder_count,
            };
        }
    };
}

pub fn Dynamic(comptime Node: type, comptime NodeInfo: type) type {
    return struct {
        const Self = @This();
        pub const StorageError = std.mem.Allocator.Error;

        pub const Compiled = struct {
            nodes: []const Node,
            root: usize,
            placeholder_names: []const []const u8,
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        infos: std.ArrayList(NodeInfo) = .empty,
        placeholder_names: std.ArrayList([]const u8) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.infos.deinit(self.allocator);
            self.placeholder_names.deinit(self.allocator);
        }

        pub fn newNode(self: *Self, node: Node, info: NodeInfo) StorageError!usize {
            const index = self.nodes.items.len;
            try self.nodes.append(self.allocator, node);
            errdefer self.nodes.items.len -= 1;
            try self.infos.append(self.allocator, info);
            return index;
        }

        pub fn nodeInfo(self: Self, index: usize) NodeInfo {
            return self.infos.items[index];
        }

        pub fn nodeAt(self: Self, index: usize) Node {
            return self.nodes.items[index];
        }

        pub fn placeholderNames(self: Self) []const []const u8 {
            return self.placeholder_names.items;
        }

        pub fn appendPlaceholder(self: *Self, name: []const u8) StorageError!usize {
            const slot = self.placeholder_names.items.len;
            try self.placeholder_names.append(self.allocator, name);
            return slot;
        }

        pub fn finish(self: *Self, root: usize) StorageError!Compiled {
            const nodes = try self.nodes.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(nodes);

            const placeholder_names = try self.placeholder_names.toOwnedSlice(self.allocator);
            return .{
                .nodes = nodes,
                .root = root,
                .placeholder_names = placeholder_names,
            };
        }
    };
}

pub fn ensureStorage(
    comptime Storage: type,
    comptime Node: type,
    comptime NodeInfo: type,
    comptime owner: []const u8,
) void {
    const declaration_options: meta.DeclLookupOptions = .{
        .owner = owner,
    };
    const method_options: meta.DeclLookupOptions = .{
        .owner = owner,
        .decl_role = "method",
    };
    const lookup_decl_type = struct {
        fn get(comptime name: []const u8) ?type {
            if (!@hasDecl(Storage, name)) return null;

            const value = @field(Storage, name);
            return if (@TypeOf(value) == type) value else @TypeOf(value);
        }
    }.get;

    meta.requireLookupDecl(
        lookup_decl_type,
        "Compiled",
        declaration_options,
    );
    meta.requireLookupDeclSatisfies(
        lookup_decl_type,
        "StorageError",
        meta.isErrorSetType,
        "an error set",
        declaration_options,
    );

    meta.requireLookupDeclType(
        lookup_decl_type,
        "deinit",
        fn (*Storage) void,
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "newNode",
        &.{fn (*Storage, Node, NodeInfo) Storage.StorageError!usize},
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "nodeInfo",
        &.{
            fn (Storage, usize) NodeInfo,
            fn (*const Storage, usize) NodeInfo,
        },
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "nodeAt",
        &.{
            fn (Storage, usize) Node,
            fn (*const Storage, usize) Node,
        },
        method_options,
    );
    meta.requireLookupDeclTypeOneOf(
        lookup_decl_type,
        "placeholderNames",
        &.{
            fn (Storage) []const []const u8,
            fn (*const Storage) []const []const u8,
        },
        method_options,
    );
    meta.requireLookupDeclType(
        lookup_decl_type,
        "appendPlaceholder",
        fn (*Storage, []const u8) Storage.StorageError!usize,
        method_options,
    );
    meta.requireLookupDeclType(
        lookup_decl_type,
        "finish",
        fn (*Storage, usize) Storage.StorageError!Storage.Compiled,
        method_options,
    );
}

test "fixed node storage records nodes and placeholders" {
    const Storage = Fixed(u8, bool, 4, 2);
    var storage: Storage = .{};

    const a = try storage.newNode(7, true);
    const b = try storage.newNode(9, false);
    _ = b;
    _ = try storage.appendPlaceholder("x");
    _ = try storage.appendPlaceholder("y");
    const compiled = try storage.finish(a);

    try std.testing.expectEqual(@as(u8, 7), compiled.nodes[compiled.root]);
    try std.testing.expectEqual(@as(usize, 2), compiled.node_count);
    try std.testing.expectEqual(@as(usize, 2), compiled.placeholder_count);
    try std.testing.expectEqualStrings("x", compiled.placeholder_names[0]);
    try std.testing.expectEqualStrings("y", compiled.placeholder_names[1]);
}

test "dynamic node storage owns nodes and placeholders" {
    const Storage = Dynamic(u8, bool);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var storage = Storage.init(arena.allocator());
    defer storage.deinit();

    const a = try storage.newNode(3, true);
    _ = try storage.newNode(5, false);
    _ = try storage.appendPlaceholder("arg");
    const compiled = try storage.finish(a);

    try std.testing.expectEqual(@as(u8, 3), compiled.nodes[compiled.root]);
    try std.testing.expectEqual(@as(usize, 2), compiled.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), compiled.placeholder_names.len);
    try std.testing.expectEqualStrings("arg", compiled.placeholder_names[0]);
}
