const std = @import("std");

const c = @import("vulkan_glfw");
const object_scene = @import("object_scene");
const spherical_scene = @import("spherical_scene");
const spherical_mesh = @import("spherical_mesh.zig");
const worlds_render = @import("worlds_render");
const space = worlds_render.space;
const png_capture = @import("png_capture.zig");
const worlds_frag_path = "zig-out/shaders/worlds.frag.spv";

const window_width = 960;
const window_height = 640;
const max_frames_in_flight = 2;

const MaxFaces = 384;
const MaxObjects = 64;
const MaxMaterials = 16;

const SphericalFrame = struct {
    width: f32,
    height: f32,
    radius: f32,
    tan_half_fov: f32,
    origin: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
};

const FrameGpu = extern struct {
    viewport: [4]f32,
    origin: Point,
    right: Direction,
    up: Direction,
    forward: Direction,
};

const ObjectGpuBlock = extern struct {
    normals: [MaxFaces][4]f32,
    meta: [MaxFaces][4]f32,
    colors: [MaxMaterials][4]f32,
    bounds: [MaxObjects][4]f32,
};

const default_object_path = "assets/spherical/world.s3obj.json";

const default_vert_path = "zig-out/shaders/vga_passthrough_raw.vert.spv";
const default_frag_path = "zig-out/shaders/vga_passthrough_raw.frag.spv";

const Point = spherical_scene.Point;
const Direction = spherical_scene.Direction;

const Vertex = extern struct {
    point: Point,
    color: [4]f32,
    plane: Point,
};

comptime {
    std.debug.assert(@sizeOf(FrameGpu) == 80);
    for (.{ "viewport", "origin", "right", "up", "forward" }, 0..) |field, index| {
        std.debug.assert(@offsetOf(FrameGpu, field) == index * 16);
    }
    std.debug.assert(@sizeOf(Vertex) == 48);
    for (.{ "point", "color", "plane" }, 0..) |field, index| {
        std.debug.assert(@offsetOf(Vertex, field) == index * 16);
    }
}

const MeshData = struct {
    vertices: []Vertex,
    indices: []u32,

    fn deinit(self: MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

const MeshTriangle = spherical_mesh.Triangle;

fn projectPoint(frame: SphericalFrame, point: Point) ?[3]f32 {
    const projection = spherical_scene.rasterProjection(
        frame.origin,
        point,
        frame.forward,
        frame.right,
        frame.up,
        frame.tan_half_fov,
        1.0,
    );
    if (!projection.valid or projection.clip_w <= 0.02) return null;
    return .{
        projection.clip_x / projection.clip_w,
        projection.clip_y / projection.clip_w,
        projection.depth,
    };
}

fn frameDirection(frame: SphericalFrame, uv: [2]f32) Direction {
    return spherical_scene.basisFrameDirection(
        frame.forward,
        frame.right,
        frame.up,
        frame.tan_half_fov,
        uv[0],
        uv[1],
    );
}

fn planeDepth(frame: SphericalFrame, dir: Direction, plane: Point) f32 {
    const intersection = spherical_scene.greatSphereIntersection(frame.origin, dir, plane);
    return (1.0 - intersection.cos_angle) * 0.5;
}

fn buildMeshData(allocator: std.mem.Allocator, triangles: []const MeshTriangle) !MeshData {
    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(allocator);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(allocator);
    var vertex_indices: std.AutoHashMap([12]u32, u32) = .init(allocator);
    defer vertex_indices.deinit();

    for (triangles) |triangle| {
        for (triangle.points) |point| {
            const vertex = Vertex{
                .point = point,
                .color = triangle.color,
                .plane = triangle.plane,
            };
            const key: *const [12]u32 = @ptrCast(&vertex);
            const entry = try vertex_indices.getOrPut(key.*);
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(vertices.items.len);
                try vertices.append(allocator, vertex);
            }
            try indices.append(allocator, entry.value_ptr.*);
        }
    }
    const owned_vertices = try vertices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_vertices);
    return .{
        .vertices = owned_vertices,
        .indices = try indices.toOwnedSlice(allocator),
    };
}

fn frameForScene(scene: spherical_scene.Scene, width: f32, height: f32) SphericalFrame {
    const camera = scene.frameCamera();
    const tracer = spherical_scene.Tracer.init(camera.pose, scene.cube, scene.fence);
    return .{
        .width = width,
        .height = height,
        .radius = tracer.radius,
        .tan_half_fov = camera.tan_half_fov,
        .origin = tracer.origin,
        .right = tracer.right,
        .up = tracer.up,
        .forward = tracer.forward,
    };
}

fn triangleContains(point: [3]f32, triangle: [3][3]f32) bool {
    const edge = struct {
        fn cross(a: [3]f32, b: [3]f32, p: [3]f32) f32 {
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        }
    }.cross;
    const a = edge(triangle[0], triangle[1], point);
    const b = edge(triangle[1], triangle[2], point);
    const c_ = edge(triangle[2], triangle[0], point);
    return (a >= -1e-4 and b >= -1e-4 and c_ >= -1e-4) or
        (a <= 1e-4 and b <= 1e-4 and c_ <= 1e-4);
}

fn triangleContainsStrict(point: [3]f32, triangle: [3][3]f32) bool {
    const edge = struct {
        fn cross(a: [3]f32, b: [3]f32, p: [3]f32) f32 {
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        }
    }.cross;
    const a = edge(triangle[0], triangle[1], point);
    const b = edge(triangle[1], triangle[2], point);
    const c_ = edge(triangle[2], triangle[0], point);
    return (a >= 0.0 and b >= 0.0 and c_ >= 0.0) or
        (a <= 0.0 and b <= 0.0 and c_ <= 0.0);
}

fn meshStrictCoversPoint(triangles: []const MeshTriangle, frame: SphericalFrame, point: Point) bool {
    const projected_point = projectPoint(frame, point) orelse return false;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (triangleContainsStrict(projected_point, .{ a, b, c_ })) return true;
    }
    return false;
}

fn meshCoversPoint(triangles: []const MeshTriangle, frame: SphericalFrame, point: Point) bool {
    const projected_point = projectPoint(frame, point) orelse return false;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (triangleContains(projected_point, .{ a, b, c_ })) return true;
    }
    return false;
}

const MeshCoverStatus = enum { none, rasterizable, filtered };

fn meshCoverStatus(triangles: []const MeshTriangle, frame: SphericalFrame, point: Point) MeshCoverStatus {
    const projected_point = projectPoint(frame, point) orelse return .none;
    var covered = false;
    for (triangles) |triangle| {
        var projected: [3][3]f32 = undefined;
        var valid = true;
        for (triangle.points, 0..) |vertex, i| {
            projected[i] = projectPoint(frame, vertex) orelse {
                valid = false;
                break;
            };
        }
        if (!valid or !triangleContains(projected_point, projected)) continue;
        covered = true;
        inline for (0..3) |i| {
            const next = (i + 1) % 3;
            const dx = projected[i][0] - projected[next][0];
            const dy = projected[i][1] - projected[next][1];
            if (@abs(projected[i][0]) > 4.0 or @abs(projected[i][1]) > 4.0 or dx * dx + dy * dy > 4.0) valid = false;
        }
        if (valid) return .rasterizable;
    }
    return if (covered) .filtered else .none;
}

const RasterHit = struct {
    object_index: ?usize = null,
    depth: f32 = 1.0,
};

const RasterCompare = struct {
    pixels: usize = 0,
    object_mismatches: usize = 0,
    depth_mismatches: usize = 0,
    first_mismatch: ?struct { x: usize, y: usize, expected: ?usize, actual: ?usize, expected_depth: f32, actual_depth: f32, mesh_covers: bool, mesh_strict_covers: bool, cover_status: MeshCoverStatus, hit_ndc: [2]f32, sample_ndc: [2]f32 } = null,
};

fn rasterCompare(triangles: []const MeshTriangle, scene: spherical_scene.Scene) !RasterCompare {
    const width = window_width;
    const height = window_height;
    const frame = frameForScene(scene, width, height);
    const raster = try std.heap.page_allocator.alloc(RasterHit, width * height);
    defer std.heap.page_allocator.free(raster);
    for (raster, 0..) |*hit, index| {
        const x = index % width;
        const y = index / width;
        const disc_u = (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0;
        const disc_v = 1.0 - (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0;
        if (disc_u * disc_u + disc_v * disc_v > 1.0) continue;
        const dir = frameDirection(frame, .{ disc_u, disc_v });
        hit.depth = planeDepth(frame, dir, Point.init(.{ 0.0, 0.0, 1.0, 0.0 }));
    }

    for (triangles) |triangle| {
        var projected: [3][3]f32 = undefined;
        var valid = true;
        for (triangle.points, 0..) |point, i| {
            const pos = projectPoint(frame, point) orelse {
                valid = false;
                break;
            };
            if (@abs(pos[0]) > 4.0 or @abs(pos[1]) > 4.0) {
                valid = false;
                break;
            }
            projected[i] = pos;
        }
        if (valid) {
            inline for (0..3) |i| {
                const next = (i + 1) % 3;
                const dx = projected[i][0] - projected[next][0];
                const dy = projected[i][1] - projected[next][1];
                if (dx * dx + dy * dy > 4.0) valid = false;
            }
        }
        if (!valid) continue;

        const left = @min(projected[0][0], @min(projected[1][0], projected[2][0]));
        const right = @max(projected[0][0], @max(projected[1][0], projected[2][0]));
        const top = @max(projected[0][1], @max(projected[1][1], projected[2][1]));
        const bottom = @min(projected[0][1], @min(projected[1][1], projected[2][1]));
        const min_x = std.math.clamp(@as(isize, @intFromFloat(@floor((left + 1.0) * 0.5 * width))), 0, width - 1);
        const max_x = std.math.clamp(@as(isize, @intFromFloat(@ceil((right + 1.0) * 0.5 * width))), 0, width - 1);
        // Vulkan's positive-height viewport maps NDC -1 to the top row.
        const min_y = std.math.clamp(@as(isize, @intFromFloat(@floor((bottom + 1.0) * 0.5 * height))), 0, height - 1);
        const max_y = std.math.clamp(@as(isize, @intFromFloat(@ceil((top + 1.0) * 0.5 * height))), 0, height - 1);
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const point = [3]f32{
                    (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0,
                    (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0 - 1.0,
                    0.0,
                };
                if (!triangleContainsStrict(point, projected)) continue;
                const dir = frameDirection(frame, .{ point[0], -point[1] });
                if (!spherical_scene.greatSphereIntersection(frame.origin, dir, triangle.plane).valid) continue;
                const depth = planeDepth(frame, dir, triangle.plane);
                const index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                if (depth < raster[index].depth) raster[index] = .{ .object_index = triangle.object_index, .depth = depth };
            }
        }
    }

    const tracer = scene.tracer();
    var result = RasterCompare{};
    for (raster, 0..) |actual, index| {
        const x = index % width;
        const y = index / width;
        const disc_uv = [2]f32{
            (@as(f32, @floatFromInt(x)) + 0.5) / width * 2.0 - 1.0,
            1.0 - (@as(f32, @floatFromInt(y)) + 0.5) / height * 2.0,
        };
        if (disc_uv[0] * disc_uv[0] + disc_uv[1] * disc_uv[1] > 1.0) continue;
        const uv = disc_uv;
        result.pixels += 1;
        const hit = tracer.trace(frameDirection(frame, uv));
        const expected: ?usize = switch (hit.surface) {
            .ground => null,
            .cube => 0,
            .fence => 1,
        };
        const actual_object = if (actual.object_index) |object_index| if (object_index == 0) @as(?usize, 0) else 1 else null;
        const expected_depth = (1.0 - hit.cos_angle) * 0.5;
        const hit_ndc = projectPoint(frame, hit.point).?;
        const sample_ndc = [2]f32{ disc_uv[0], -disc_uv[1] };
        if (expected != actual_object) {
            result.object_mismatches += 1;
            if (result.first_mismatch == null) result.first_mismatch = .{ .x = x, .y = y, .expected = expected, .actual = actual_object, .expected_depth = expected_depth, .actual_depth = actual.depth, .mesh_covers = meshCoversPoint(triangles, frame, hit.point), .mesh_strict_covers = meshStrictCoversPoint(triangles, frame, hit.point), .cover_status = meshCoverStatus(triangles, frame, hit.point), .hit_ndc = .{ hit_ndc[0], hit_ndc[1] }, .sample_ndc = sample_ndc };
        } else if (expected != null and @abs(expected_depth - actual.depth) > 1e-3) {
            result.depth_mismatches += 1;
            if (result.first_mismatch == null) result.first_mismatch = .{ .x = x, .y = y, .expected = expected, .actual = actual_object, .expected_depth = expected_depth, .actual_depth = actual.depth, .mesh_covers = meshCoversPoint(triangles, frame, hit.point), .mesh_strict_covers = meshStrictCoversPoint(triangles, frame, hit.point), .cover_status = meshCoverStatus(triangles, frame, hit.point), .hit_ndc = .{ hit_ndc[0], hit_ndc[1] }, .sample_ndc = sample_ndc };
        }
    }
    return result;
}

fn meshSelfCheck(triangles: []const MeshTriangle, compare: bool) !void {
    const poses = [_]spherical_scene.Scene{
        spherical_scene.Scene.init(),
        blk: {
            var scene = spherical_scene.Scene.init();
            scene.walkForward(1.0);
            scene.yaw(0.35);
            break :blk scene;
        },
        blk: {
            var scene = spherical_scene.Scene.init();
            scene.walkForward(4.0);
            scene.pitch(-0.35);
            break :blk scene;
        },
    };
    var expected_objects: usize = 0;
    var covered_objects: usize = 0;
    var samples: usize = 0;
    for (poses) |scene| {
        const frame = frameForScene(scene, 96.0, 64.0);
        const tracer = scene.tracer();
        var y: usize = 0;
        while (y < 6) : (y += 1) {
            var x: usize = 0;
            while (x < 8) : (x += 1) {
                const pixel = [2]f32{ @floatFromInt(x * 2 + 1), @floatFromInt(y * 2 + 1) };
                const uv = [2]f32{
                    pixel[0] / frame.width * 2.0 - 1.0,
                    (1.0 - pixel[1] / frame.height) * 2.0 - 1.0,
                };
                if (uv[0] * uv[0] + uv[1] * uv[1] > 1.0) continue;
                const dir = frameDirection(frame, uv);
                const hit = tracer.trace(dir);
                const object_hit = switch (hit.surface) {
                    .ground => false,
                    .fence, .cube => true,
                };
                if (object_hit) {
                    expected_objects += 1;
                    if (meshCoversPoint(triangles, frame, hit.point)) covered_objects += 1;
                }
                samples += 1;
            }
        }
    }
    const frame = frameForScene(spherical_scene.Scene.init(), 960.0, 640.0);
    const tracer = spherical_scene.Scene.init().tracer();
    const dir = frameDirection(frame, .{ 0.0, 0.0 });
    const hit = tracer.trace(dir);
    const projected = projectPoint(frame, hit.point).?;
    var nearest_depth: f32 = 1.0;
    var nearest_color: ?[4]f32 = null;
    var strict_hits: usize = 0;
    var strict_valid_hits: usize = 0;
    for (triangles) |triangle| {
        const a = projectPoint(frame, triangle.points[0]) orelse continue;
        const b = projectPoint(frame, triangle.points[1]) orelse continue;
        const c_ = projectPoint(frame, triangle.points[2]) orelse continue;
        if (!triangleContains(projected, .{ a, b, c_ })) continue;
        if (triangleContainsStrict(projected, .{ a, b, c_ })) {
            strict_hits += 1;
            if (spherical_scene.greatSphereIntersection(frame.origin, dir, triangle.plane).valid) strict_valid_hits += 1;
        }
        const depth = planeDepth(frame, dir, triangle.plane);
        if (depth < nearest_depth) {
            nearest_depth = depth;
            nearest_color = triangle.color;
        }
    }
    std.debug.print("mesh self-check: {d}/{d} object hits covered across {d} samples; center cpu={d:.6} mesh={d:.6} ground={d:.6} strict={d}/{d} color={any}\n", .{ covered_objects, expected_objects, samples, (1.0 - hit.cos_angle) * 0.5, nearest_depth, planeDepth(frame, dir, Point.init(.{ 0.0, 0.0, 1.0, 0.0 })), strict_valid_hits, strict_hits, nearest_color });
    if (compare) {
        for (poses, 0..) |pose, i| {
            const comparison = try rasterCompare(triangles, pose);
            std.debug.print("mesh raster compare pose {d}: {d} pixels, object mismatches={d}, depth mismatches={d}, first={any}\n", .{ i, comparison.pixels, comparison.object_mismatches, comparison.depth_mismatches, comparison.first_mismatch });
        }
    }
}

const QueueFamilyIndices = struct {
    graphics: ?u32 = null,
    present: ?u32 = null,

    fn complete(self: QueueFamilyIndices) bool {
        return self.graphics != null and self.present != null;
    }
};

const SwapchainSupport = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    present_modes: []c.VkPresentModeKHR,

    fn deinit(self: SwapchainSupport, allocator: std.mem.Allocator) void {
        allocator.free(self.formats);
        allocator.free(self.present_modes);
    }
};

const PipelineBundle = struct {
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    world: spherical_scene.Scene,
    worlds_mode: ?space.Mode = null,
    requested_world: ?space.Kind = null,
    scroll_delta: f32 = 0,
    capture_path: ?[]const u8 = null,
    object_block: ObjectGpuBlock,
    mesh_data: MeshData,
    mesh_triangle_count: usize,
    mesh_vertex_count: u32,
    mesh_index_count: u32,
    window: ?*c.GLFWwindow = null,

    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    queue_families: QueueFamilyIndices = .{},

    swapchain: c.VkSwapchainKHR = null,
    swapchain_images: []c.VkImage = &.{},
    swapchain_image_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    swapchain_image_views: []c.VkImageView = &.{},
    framebuffers: []c.VkFramebuffer = &.{},
    depth_image: c.VkImage = null,
    depth_image_memory: c.VkDeviceMemory = null,
    depth_image_view: c.VkImageView = null,

    render_pass: c.VkRenderPass = null,
    pipeline_layout: c.VkPipelineLayout = null,
    graphics_pipeline: c.VkPipeline = null,
    mesh_pipeline_layout: c.VkPipelineLayout = null,
    mesh_pipeline: c.VkPipeline = null,
    worlds_pipeline_layout: c.VkPipelineLayout = null,
    worlds_pipeline: c.VkPipeline = null,

    command_pool: c.VkCommandPool = null,
    command_buffers: []c.VkCommandBuffer = &.{},

    vertex_buffer: c.VkBuffer = null,
    vertex_buffer_memory: c.VkDeviceMemory = null,
    index_buffer: c.VkBuffer = null,
    index_buffer_memory: c.VkDeviceMemory = null,
    object_buffer: c.VkBuffer = null,
    object_buffer_memory: c.VkDeviceMemory = null,
    frame_buffer: c.VkBuffer = null,
    frame_buffer_memory: c.VkDeviceMemory = null,
    capture_buffer: c.VkBuffer = null,
    capture_buffer_memory: c.VkDeviceMemory = null,
    frame_stride: c.VkDeviceSize = 0,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_sets: []c.VkDescriptorSet = &.{},
    images_in_flight: []c.VkFence = &.{},

    image_available: [max_frames_in_flight]c.VkSemaphore = @splat(null),
    render_finished: []c.VkSemaphore = &.{}, // Presentation waits belong to swapchain images, not frame slots.
    in_flight: [max_frames_in_flight]c.VkFence = @splat(null),
    current_frame: usize = 0,

    framebuffer_resized: bool = false,
    vert_path: []const u8 = default_vert_path,
    frag_path: []const u8 = default_frag_path,
    mesh_vert_path: ?[]const u8 = null,
    mesh_frag_path: ?[]const u8 = null,
    benchmark_frames: u32 = 0,
    rendered_frames: u32 = 0,
    benchmark_started_at: f64 = 0.0,
    fps_frames: u32 = 0,
    fps_last_update: f64 = 0.0,
    vert_mtime: i128 = 0,
    frag_mtime: i128 = 0,
    worlds_frag_mtime: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, vert_path: []const u8, frag_path: []const u8, mesh_vert_path: ?[]const u8, mesh_frag_path: ?[]const u8, benchmark_frames: u32, world: spherical_scene.Scene, compare: bool, worlds_mode: ?space.Mode, capture_path: ?[]const u8) !App {
        const object_text = try std.Io.Dir.cwd().readFileAlloc(io, default_object_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(object_text);
        const parsed = try object_scene.parse(allocator, object_text);
        defer parsed.deinit();
        var object_block: ObjectGpuBlock = undefined;
        @memset(std.mem.asBytes(&object_block), 0);
        try fillObjectBlock(&object_block, parsed.value);
        const mesh_triangles = try spherical_mesh.buildTriangles(allocator, parsed.value);
        defer allocator.free(mesh_triangles);
        try meshSelfCheck(mesh_triangles, compare);
        const mesh_data = try buildMeshData(allocator, mesh_triangles);

        var app = App{
            .allocator = allocator,
            .io = io,
            .world = world,
            .worlds_mode = worlds_mode,
            .capture_path = capture_path,
            .object_block = object_block,
            .mesh_data = mesh_data,
            .mesh_triangle_count = mesh_triangles.len,
            .mesh_vertex_count = @intCast(mesh_data.vertices.len),
            .mesh_index_count = @intCast(mesh_data.indices.len),
            .vert_path = vert_path,
            .frag_path = frag_path,
            .mesh_vert_path = mesh_vert_path,
            .mesh_frag_path = mesh_frag_path,
            .benchmark_frames = benchmark_frames,
        };
        errdefer app.deinit();

        try app.initWindow();
        try app.initVulkan();
        app.vert_mtime = fileMtime(app.io, vert_path) catch 0;
        app.frag_mtime = fileMtime(app.io, frag_path) catch 0;
        if (worlds_mode != null) app.worlds_frag_mtime = fileMtime(app.io, worlds_frag_path) catch 0;
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.device != null) _ = c.vkDeviceWaitIdle(self.device);

        self.cleanupSwapchain();

        if (self.vertex_buffer != null) c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        if (self.vertex_buffer_memory != null) c.vkFreeMemory(self.device, self.vertex_buffer_memory, null);
        if (self.index_buffer != null) c.vkDestroyBuffer(self.device, self.index_buffer, null);
        if (self.index_buffer_memory != null) c.vkFreeMemory(self.device, self.index_buffer_memory, null);
        self.mesh_data.deinit(self.allocator);
        if (self.object_buffer != null) c.vkDestroyBuffer(self.device, self.object_buffer, null);
        if (self.object_buffer_memory != null) c.vkFreeMemory(self.device, self.object_buffer_memory, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);

        for (0..max_frames_in_flight) |i| {
            if (self.image_available[i] != null) c.vkDestroySemaphore(self.device, self.image_available[i], null);
            if (self.in_flight[i] != null) c.vkDestroyFence(self.device, self.in_flight[i], null);
        }

        if (self.command_pool != null) c.vkDestroyCommandPool(self.device, self.command_pool, null);
        if (self.device != null) c.vkDestroyDevice(self.device, null);
        if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        if (self.window) |window| c.glfwDestroyWindow(window);
        c.glfwTerminate();
    }

    pub fn run(self: *App) !void {
        c.glfwSetWindowUserPointer(self.window, self);
        self.updateWindowTitle();
        if (self.worlds_mode != null) std.debug.print("worlds: Vulkan GPU rendering, 1-4/Tab switch, click selectors, Q/E rotate isometric, wheel zoom\n", .{});
        std.debug.print("shader playground\n", .{});
        std.debug.print("  vertex:   {s}\n", .{self.vert_path});
        std.debug.print("  fragment: {s}\n", .{self.frag_path});
        std.debug.print("  mesh triangles: {d}, persistent vertices: {d}, indices: {d}\n", .{ self.mesh_triangle_count, self.mesh_vertex_count, self.mesh_index_count });
        std.debug.print("  controls: W/S walk, A/D strafe, arrows look, R reset, Esc quit\n", .{});
        std.debug.print("Run this in another terminal for live SPIR-V rebuilds:\n", .{});
        if (self.worlds_mode != null) {
            std.debug.print("  zig build --watch spirv-worlds\n\n", .{});
        } else {
            std.debug.print("  zig build --watch spirv-raw     # driver-valid raw baseline\n", .{});
            std.debug.print("  zig build --watch spirv-vga     # GA shaders, currently useful for compiler/driver debugging\n\n", .{});
        }

        var dirty = true;
        self.benchmark_started_at = c.glfwGetTime();
        var previous_time = self.benchmark_started_at;
        self.fps_last_update = self.benchmark_started_at;
        while (c.glfwWindowShouldClose(self.window) == c.GLFW_FALSE) {
            if (self.benchmark_frames == 0) c.glfwWaitEventsTimeout(1.0 / 60.0) else c.glfwPollEvents();
            const now = c.glfwGetTime();
            const delta_time: f32 = @floatCast(@min(now - previous_time, 0.1));
            previous_time = now;

            if (self.benchmark_frames > 0) dirty = true;
            if (self.framebuffer_resized) dirty = true;
            if (try self.reloadShadersIfChanged()) dirty = true;
            if (self.capture_path == null and try self.updateInput(delta_time)) dirty = true;
            if (dirty) {
                if (!try self.drawFrame()) continue;
                self.rendered_frames += 1;
                self.fps_frames += 1;
                dirty = false;
                if (self.benchmark_frames > 0 and self.rendered_frames >= self.benchmark_frames) {
                    try vkCheck(c.vkDeviceWaitIdle(self.device));
                    const elapsed = c.glfwGetTime() - self.benchmark_started_at;
                    std.debug.print("benchmark: {d} frames, {d:.3}s, {d:.1} fps\n", .{ self.rendered_frames, elapsed, @as(f64, @floatFromInt(self.rendered_frames)) / @max(elapsed, 0.000001) });
                    c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
                }
            }

            if (self.benchmark_frames == 0) {
                const fps_elapsed = now - self.fps_last_update;
                if (fps_elapsed >= 0.5) {
                    const fps = @as(f64, @floatFromInt(self.fps_frames)) / fps_elapsed;
                    std.debug.print("\r{d: >5.0} fps  ", .{fps});
                    self.fps_frames = 0;
                    self.fps_last_update = now;
                    self.updateWindowTitle();
                }
            }
        }
        try vkCheck(c.vkDeviceWaitIdle(self.device));
    }

    fn updateInput(self: *App, delta_time: f32) !bool {
        if (self.keyDown(c.GLFW_KEY_ESCAPE)) {
            c.glfwSetWindowShouldClose(self.window, c.GLFW_TRUE);
            return false;
        }

        if (self.worlds_mode != null) return self.updateWorldsInput(delta_time);

        const speed_scale = spherical_scene.Scene.speedScaleForGap(self.world.conjugateGap());
        const move = 2.2 * speed_scale * delta_time;
        const turn = 1.35 * delta_time;
        var changed = false;
        if (self.keyDown(c.GLFW_KEY_W)) {
            self.world.walkForward(move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_S)) {
            self.world.walkForward(-move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_D)) {
            self.world.strafeRight(move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_A)) {
            self.world.strafeRight(-move);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_RIGHT)) {
            self.world.yaw(-turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_LEFT)) {
            self.world.yaw(turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_UP)) {
            self.world.pitch(-turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_DOWN)) {
            self.world.pitch(turn);
            changed = true;
        }
        if (self.keyDown(c.GLFW_KEY_R)) {
            self.world = spherical_scene.Scene.init();
            changed = true;
        }
        return changed;
    }

    fn updateWorldsInput(self: *App, dt: f32) !bool {
        var changed = false;
        if (self.requested_world) |kind| {
            self.requested_world = null;
            self.worlds_mode = space.Mode.init(kind);
            try vkCheck(c.vkDeviceWaitIdle(self.device));
            try self.recreateCommandBuffers();
            self.updateWindowTitle();
            changed = true;
        }
        const mode = &self.worlds_mode.?;
        if (self.keyDown(c.GLFW_KEY_R)) {
            mode.* = space.Mode.init(std.meta.activeTag(mode.*));
            changed = true;
        }
        const forward = self.keyAxis(c.GLFW_KEY_W, c.GLFW_KEY_S);
        const strafe = self.keyAxis(c.GLFW_KEY_D, c.GLFW_KEY_A);
        const yaw = if (mode.* == .isometric) self.keyAxis(c.GLFW_KEY_Q, c.GLFW_KEY_E) else self.keyAxis(c.GLFW_KEY_LEFT, c.GLFW_KEY_RIGHT);
        const pitch = self.keyAxis(c.GLFW_KEY_UP, c.GLFW_KEY_DOWN);
        const zoom = self.scroll_delta;
        self.scroll_delta = 0;
        if (forward == 0 and strafe == 0 and yaw == 0 and pitch == 0 and zoom == 0) return changed;
        switch (mode.*) {
            .euclidean => |*view| {
                view.* = view.walkForward(forward * 4 * dt).strafeRight(strafe * 4 * dt).yawBy(yaw * 1.6 * dt).pitchBy(pitch * 1.6 * dt);
            },
            .isometric => |*view| {
                view.* = view.pan(strafe * 8 * dt, forward * 8 * dt).yawBy(yaw * 1.4 * dt);
                if (zoom != 0) view.* = view.zoom(@max(0.1, 1 + 0.12 * zoom));
            },
            .spherical => |*world| {
                const move = 2.2 * spherical_scene.Scene.speedScaleForGap(world.conjugateGap()) * dt;
                if (forward != 0) world.walkForward(forward * move);
                if (strafe != 0) world.strafeRight(strafe * move);
                if (yaw != 0) world.yaw(yaw * 1.35 * dt);
                if (pitch != 0) world.pitch(-pitch * 1.35 * dt);
            },
            .hyperbolic => |*pose| {
                if (forward != 0) pose.* = pose.walkForward(forward * 2.2 * dt);
                if (strafe != 0) pose.* = pose.strafeRight(strafe * 2.2 * dt);
                if (yaw != 0) pose.* = pose.yaw(yaw * 1.35 * dt);
                if (pitch != 0) pose.* = pose.pitch(pitch * 1.35 * dt);
            },
        }
        return true;
    }

    fn updateWindowTitle(self: *App) void {
        if (self.worlds_mode) |mode| {
            var buffer: [256]u8 = undefined;
            const title = std.mem.printSentinel(&buffer, "zmath worlds: {s} | {s}", .{ @tagName(std.meta.activeTag(mode)), mode.hint() }, 0) catch return;
            c.glfwSetWindowTitle(self.window, title);
        }
    }

    fn keyAxis(self: *App, positive: c_int, negative: c_int) f32 {
        return @as(f32, if (self.keyDown(positive)) 1 else 0) - @as(f32, if (self.keyDown(negative)) 1 else 0);
    }

    fn keyDown(self: *App, key: c_int) bool {
        return c.glfwGetKey(self.window, key) == c.GLFW_PRESS;
    }

    fn initWindow(self: *App) !void {
        if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
        if (c.glfwVulkanSupported() != c.GLFW_TRUE) return error.GlfwVulkanUnavailable;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
        if (self.capture_path != null) c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
        self.window = c.glfwCreateWindow(window_width, window_height, "zmath SPIR-V playground", null, null) orelse return error.GlfwCreateWindowFailed;
        c.glfwSetWindowUserPointer(self.window, self);
        _ = c.glfwSetFramebufferSizeCallback(self.window, framebufferResizeCallback);
        if (self.worlds_mode != null) {
            _ = c.glfwSetKeyCallback(self.window, worldKeyCallback);
            _ = c.glfwSetScrollCallback(self.window, worldScrollCallback);
            _ = c.glfwSetMouseButtonCallback(self.window, worldMouseCallback);
        }
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createObjectResources();
        try self.createSwapchain();
        try self.createFrameResources();
        try self.createImageViews();
        try self.createRenderPass();
        try self.createDepthResources();
        try self.createPipelines();
        try self.createFramebuffers();
        try self.createCommandPool();
        try self.createVertexBuffer();
        self.mesh_data.deinit(self.allocator);
        self.mesh_data = .{ .vertices = &.{}, .indices = &.{} };
        try self.createCommandBuffers();
        try self.createSyncObjects();
    }

    fn createInstance(self: *App) !void {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions_ptr = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count) orelse return error.GlfwVulkanUnavailable;

        const app_name = "zmath shader playground";
        const engine_name = "zmath";
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = app_name,
            .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = engine_name,
            .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = c.VK_API_VERSION_1_2,
        };

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = glfw_extension_count,
            .ppEnabledExtensionNames = glfw_extensions_ptr,
        };

        try vkCheck(c.vkCreateInstance(&create_info, null, &self.instance));
    }

    fn createSurface(self: *App) !void {
        try vkCheck(c.glfwCreateWindowSurface(self.instance, self.window, null, &self.surface));
    }

    fn pickPhysicalDevice(self: *App) !void {
        var device_count: u32 = 0;
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, null));
        if (device_count == 0) return error.NoVulkanDevices;

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);
        try vkCheck(c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr));

        for (devices) |device| {
            if (try self.isDeviceSuitable(device)) {
                self.physical_device = device;
                self.queue_families = try self.findQueueFamilies(device);
                return;
            }
        }
        return error.NoSuitableVulkanDevice;
    }

    fn isDeviceSuitable(self: *App, device: c.VkPhysicalDevice) !bool {
        var properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(device, &properties);
        if (properties.apiVersion < c.VK_API_VERSION_1_2) return false;
        const indices = try self.findQueueFamilies(device);
        if (!indices.complete()) return false;
        if (!try self.checkDeviceExtensionSupport(device)) return false;

        const support = try self.querySwapchainSupport(device);
        defer support.deinit(self.allocator);
        return support.formats.len > 0 and support.present_modes.len > 0;
    }

    fn checkDeviceExtensionSupport(self: *App, device: c.VkPhysicalDevice) !bool {
        var extension_count: u32 = 0;
        try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null));
        const extensions = try self.allocator.alloc(c.VkExtensionProperties, extension_count);
        defer self.allocator.free(extensions);
        try vkCheck(c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr));

        for (extensions) |extension| {
            const name = std.mem.sliceTo(&extension.extensionName, 0);
            if (std.mem.eql(u8, name, "VK_KHR_swapchain")) return true;
        }
        return false;
    }

    fn findQueueFamilies(self: *App, device: c.VkPhysicalDevice) !QueueFamilyIndices {
        var indices = QueueFamilyIndices{};
        var queue_family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
        const families = try self.allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer self.allocator.free(families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, families.ptr);

        for (families, 0..) |family, i| {
            const index: u32 = @intCast(i);
            if ((family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) indices.graphics = index;

            var present_support: c.VkBool32 = c.VK_FALSE;
            try vkCheck(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, index, self.surface, &present_support));
            if (present_support == c.VK_TRUE) indices.present = index;

            if (indices.complete()) break;
        }
        return indices;
    }

    fn createLogicalDevice(self: *App) !void {
        const graphics_family = self.queue_families.graphics.?;
        const present_family = self.queue_families.present.?;
        const queue_priority: f32 = 1.0;

        var queue_create_infos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queue_create_info_count: u32 = 0;

        queue_create_infos[queue_create_info_count] = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        queue_create_info_count += 1;

        if (present_family != graphics_family) {
            queue_create_infos[queue_create_info_count] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_create_info_count += 1;
        }

        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        const device_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        const create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_create_info_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = @ptrCast(&device_extensions),
            .pEnabledFeatures = &device_features,
        };

        try vkCheck(c.vkCreateDevice(self.physical_device, &create_info, null, &self.device));
        c.vkGetDeviceQueue(self.device, graphics_family, 0, &self.graphics_queue);
        c.vkGetDeviceQueue(self.device, present_family, 0, &self.present_queue);
    }

    fn querySwapchainSupport(self: *App, device: c.VkPhysicalDevice) !SwapchainSupport {
        var support: SwapchainSupport = undefined;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, self.surface, &support.capabilities));

        var format_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, null));
        support.formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        errdefer self.allocator.free(support.formats);
        if (format_count > 0) try vkCheck(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, self.surface, &format_count, support.formats.ptr));

        var present_mode_count: u32 = 0;
        try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &present_mode_count, null));
        support.present_modes = try self.allocator.alloc(c.VkPresentModeKHR, present_mode_count);
        errdefer self.allocator.free(support.present_modes);
        if (present_mode_count > 0) try vkCheck(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, self.surface, &present_mode_count, support.present_modes.ptr));

        return support;
    }

    fn createObjectResources(self: *App) !void {
        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
            .{
                .binding = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .pImmutableSamplers = null,
            },
        };
        const layout_info = c.VkDescriptorSetLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };
        try vkCheck(c.vkCreateDescriptorSetLayout(self.device, &layout_info, null, &self.descriptor_set_layout));

        try self.createBuffer(
            @sizeOf(ObjectGpuBlock),
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.object_buffer,
            &self.object_buffer_memory,
        );
        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.object_buffer_memory, 0, @sizeOf(ObjectGpuBlock), 0, &mapped));
        const bytes = std.mem.asBytes(&self.object_block);
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..bytes.len], bytes);
        c.vkUnmapMemory(self.device, self.object_buffer_memory);
    }

    fn createFrameResources(self: *App) !void {
        var properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(self.physical_device, &properties);
        const alignment = properties.limits.minUniformBufferOffsetAlignment;
        self.frame_stride = std.mem.alignForward(c.VkDeviceSize, self.frameSize(), @max(alignment, 1));
        try self.createBuffer(
            self.frame_stride * self.swapchain_images.len,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.frame_buffer,
            &self.frame_buffer_memory,
        );

        const set_count: u32 = @intCast(self.swapchain_images.len);
        const pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = set_count },
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = set_count },
        };
        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = set_count,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };
        try vkCheck(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));

        self.descriptor_sets = try self.allocator.alloc(c.VkDescriptorSet, self.swapchain_images.len);
        const layouts = try self.allocator.alloc(c.VkDescriptorSetLayout, self.swapchain_images.len);
        defer self.allocator.free(layouts);
        @memset(layouts, self.descriptor_set_layout);
        const allocate_info = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = set_count,
            .pSetLayouts = layouts.ptr,
        };
        try vkCheck(c.vkAllocateDescriptorSets(self.device, &allocate_info, self.descriptor_sets.ptr));

        const object_info = c.VkDescriptorBufferInfo{ .buffer = self.object_buffer, .offset = 0, .range = @sizeOf(ObjectGpuBlock) };
        for (self.descriptor_sets, 0..) |descriptor_set, i| {
            const frame_info = c.VkDescriptorBufferInfo{ .buffer = self.frame_buffer, .offset = self.frame_stride * i, .range = self.frameSize() };
            const writes = [_]c.VkWriteDescriptorSet{
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = descriptor_set,
                    .dstBinding = 0,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pImageInfo = null,
                    .pBufferInfo = &object_info,
                    .pTexelBufferView = null,
                },
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = descriptor_set,
                    .dstBinding = 1,
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .pImageInfo = null,
                    .pBufferInfo = &frame_info,
                    .pTexelBufferView = null,
                },
            };
            c.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
        }

        if (self.capture_path != null) {
            var buffer: c.VkBuffer = null;
            var memory: c.VkDeviceMemory = null;
            try self.createBuffer(self.captureSize(), c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &buffer, &memory);
            self.capture_buffer = buffer;
            self.capture_buffer_memory = memory;
        }
        self.images_in_flight = try self.allocator.alloc(c.VkFence, self.swapchain_images.len);
        @memset(self.images_in_flight, null);
        self.render_finished = try self.allocator.alloc(c.VkSemaphore, self.swapchain_images.len);
        @memset(self.render_finished, null);
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        for (self.render_finished) |*semaphore| {
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, semaphore));
        }
    }

    fn createSwapchain(self: *App) !void {
        const support = try self.querySwapchainSupport(self.physical_device);
        defer support.deinit(self.allocator);

        const surface_format = chooseSwapSurfaceFormat(support.formats);
        if (self.capture_path != null) {
            if (support.capabilities.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT == 0) return error.UnsupportedCaptureTransfer;
            switch (surface_format.format) {
                c.VK_FORMAT_B8G8R8A8_SRGB, c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_SRGB, c.VK_FORMAT_R8G8B8A8_UNORM => {},
                else => return error.UnsupportedCaptureFormat,
            }
        }
        const present_mode = chooseSwapPresentMode(support.present_modes);
        const extent = chooseSwapExtent(self.window, support.capabilities);

        var image_count = support.capabilities.minImageCount + 1;
        if (support.capabilities.maxImageCount > 0 and image_count > support.capabilities.maxImageCount) {
            image_count = support.capabilities.maxImageCount;
        }

        const queue_family_indices = [_]u32{ self.queue_families.graphics.?, self.queue_families.present.? };
        const sharing_mode: c.VkSharingMode = if (queue_family_indices[0] != queue_family_indices[1]) c.VK_SHARING_MODE_CONCURRENT else c.VK_SHARING_MODE_EXCLUSIVE;
        const queue_family_index_count: u32 = if (sharing_mode == c.VK_SHARING_MODE_CONCURRENT) 2 else 0;
        const queue_family_index_ptr: [*c]const u32 = if (sharing_mode == c.VK_SHARING_MODE_CONCURRENT) queue_family_indices[0..].ptr else null;

        const create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) | (if (self.capture_path != null) @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) else 0),
            .imageSharingMode = sharing_mode,
            .queueFamilyIndexCount = queue_family_index_count,
            .pQueueFamilyIndices = queue_family_index_ptr,
            .preTransform = support.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        try vkCheck(c.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain));

        var actual_image_count: u32 = 0;
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null));
        self.swapchain_images = try self.allocator.alloc(c.VkImage, actual_image_count);
        try vkCheck(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, self.swapchain_images.ptr));

        self.swapchain_image_format = surface_format.format;
        self.swapchain_extent = extent;
    }

    fn createImageViews(self: *App) !void {
        self.swapchain_image_views = try self.allocator.alloc(c.VkImageView, self.swapchain_images.len);
        errdefer self.allocator.free(self.swapchain_image_views);

        for (self.swapchain_images, 0..) |image, i| {
            const create_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_image_format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };
            try vkCheck(c.vkCreateImageView(self.device, &create_info, null, &self.swapchain_image_views[i]));
        }
    }

    fn createRenderPass(self: *App) !void {
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_image_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };
        const depth_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const depth_attachment_ref = c.VkAttachmentReference{
            .attachment = 1,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_attachment_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const attachments = [_]c.VkAttachmentDescription{ color_attachment, depth_attachment };
        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 2,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        try vkCheck(c.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass));
    }

    fn createGraphicsPipeline(self: *App) !PipelineBundle {
        return self.createPipeline(self.vert_path, self.frag_path, false, false);
    }

    fn createMeshPipeline(self: *App) !PipelineBundle {
        return self.createPipeline(self.mesh_vert_path.?, self.mesh_frag_path.?, true, false);
    }

    fn createPipelines(self: *App) !void {
        const ground = try self.createGraphicsPipeline();
        self.pipeline_layout = ground.layout;
        self.graphics_pipeline = ground.pipeline;
        if (self.mesh_vert_path != null and self.mesh_frag_path != null) {
            const mesh = try self.createMeshPipeline();
            self.mesh_pipeline_layout = mesh.layout;
            self.mesh_pipeline = mesh.pipeline;
        }
        if (self.worlds_mode != null) {
            const worlds = try self.createPipeline(self.vert_path, worlds_frag_path, false, true);
            self.worlds_pipeline_layout = worlds.layout;
            self.worlds_pipeline = worlds.pipeline;
        }
    }

    fn createPipeline(self: *App, vert_path: []const u8, frag_path: []const u8, mesh: bool, blend: bool) !PipelineBundle {
        const vert_words = try readSpirvWords(self.allocator, self.io, vert_path);
        defer self.allocator.free(vert_words);
        const frag_words = try readSpirvWords(self.allocator, self.io, frag_path);
        defer self.allocator.free(frag_words);

        const vert_module = try self.createShaderModule(vert_words);
        defer c.vkDestroyShaderModule(self.device, vert_module, null);
        const frag_module = try self.createShaderModule(frag_words);
        defer c.vkDestroyShaderModule(self.device, frag_module, null);

        const main_name = "main";
        const shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = main_name,
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = main_name,
                .pSpecializationInfo = null,
            },
        };

        const vertex_binding = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };
        const vertex_attributes = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "point") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "color") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "plane") },
        };
        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = if (mesh) 1 else 0,
            .pVertexBindingDescriptions = if (mesh) &vertex_binding else null,
            .vertexAttributeDescriptionCount = if (mesh) 3 else 0,
            .pVertexAttributeDescriptions = if (mesh) &vertex_attributes else null,
        };
        const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };
        const viewport = c.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        const scissor = c.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &scissor,
        };
        const rasterizer = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0.0,
            .depthBiasClamp = 0.0,
            .depthBiasSlopeFactor = 0.0,
            .lineWidth = 1.0,
        };
        const multisampling = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };
        const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = if (blend) c.VK_TRUE else c.VK_FALSE,
            .srcColorBlendFactor = if (blend) c.VK_BLEND_FACTOR_SRC_ALPHA else c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = if (blend) c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA else c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = if (blend) c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA else c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const color_blending = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        var pipeline_layout: c.VkPipelineLayout = null;
        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_set_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        try vkCheck(c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(self.device, pipeline_layout, null);

        const depth_stencil = c.VkPipelineDepthStencilStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = if (blend) c.VK_FALSE else c.VK_TRUE,
            .depthWriteEnable = if (blend) c.VK_FALSE else c.VK_TRUE,
            .depthCompareOp = if (mesh) c.VK_COMPARE_OP_LESS else c.VK_COMPARE_OP_ALWAYS,
            .depthBoundsTestEnable = c.VK_FALSE,
            .stencilTestEnable = c.VK_FALSE,
            .front = std.mem.zeroes(c.VkStencilOpState),
            .back = std.mem.zeroes(c.VkStencilOpState),
            .minDepthBounds = 0.0,
            .maxDepthBounds = 1.0,
        };
        const pipeline_info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = shader_stages.len,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blending,
            .pDynamicState = null,
            .layout = pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: c.VkPipeline = null;
        try vkCheck(c.vkCreateGraphicsPipelines(self.device, null, 1, &pipeline_info, null, &pipeline));
        errdefer c.vkDestroyPipeline(self.device, pipeline, null);

        return .{ .layout = pipeline_layout, .pipeline = pipeline };
    }

    fn createShaderModule(self: *App, words: []const u32) !c.VkShaderModule {
        const create_info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = words.len * @sizeOf(u32),
            .pCode = words.ptr,
        };
        var shader_module: c.VkShaderModule = null;
        try vkCheck(c.vkCreateShaderModule(self.device, &create_info, null, &shader_module));
        return shader_module;
    }

    fn createDepthResources(self: *App) !void {
        const image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .extent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vkCheck(c.vkCreateImage(self.device, &image_info, null, &self.depth_image));
        errdefer c.vkDestroyImage(self.device, self.depth_image, null);

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.depth_image, &requirements);
        const allocation = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = try self.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &allocation, null, &self.depth_image_memory));
        errdefer c.vkFreeMemory(self.device, self.depth_image_memory, null);
        try vkCheck(c.vkBindImageMemory(self.device, self.depth_image, self.depth_image_memory, 0));

        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = self.depth_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_D32_SFLOAT,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        try vkCheck(c.vkCreateImageView(self.device, &view_info, null, &self.depth_image_view));
    }

    fn createFramebuffers(self: *App) !void {
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len);
        errdefer self.allocator.free(self.framebuffers);

        for (self.swapchain_image_views, 0..) |image_view, i| {
            const attachments = [_]c.VkImageView{ image_view, self.depth_image_view };
            const framebuffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 2,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };
            try vkCheck(c.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]));
        }
    }

    fn createCommandPool(self: *App) !void {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_families.graphics.?,
        };
        try vkCheck(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
    }

    fn createVertexBuffer(self: *App) !void {
        try self.createDeviceBufferWithData(
            std.mem.sliceAsBytes(self.mesh_data.vertices),
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );
        try self.createDeviceBufferWithData(
            std.mem.sliceAsBytes(self.mesh_data.indices),
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
            &self.index_buffer,
            &self.index_buffer_memory,
        );
    }

    fn createDeviceBufferWithData(self: *App, bytes: []const u8, usage: c.VkBufferUsageFlags, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory) !void {
        const buffer_size: c.VkDeviceSize = @intCast(bytes.len);
        var staging_buffer: c.VkBuffer = null;
        var staging_memory: c.VkDeviceMemory = null;
        try self.createBuffer(
            buffer_size,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &staging_buffer,
            &staging_memory,
        );
        defer c.vkDestroyBuffer(self.device, staging_buffer, null);
        defer c.vkFreeMemory(self.device, staging_memory, null);

        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, staging_memory, 0, buffer_size, 0, &mapped));
        @memcpy(@as([*]u8, @ptrCast(mapped.?))[0..bytes.len], bytes);
        c.vkUnmapMemory(self.device, staging_memory);

        try self.createBuffer(
            buffer_size,
            @as(c.VkBufferUsageFlags, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT) | usage,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            buffer,
            memory,
        );
        try self.copyBuffer(staging_buffer, buffer.*, buffer_size);
    }

    fn copyBuffer(self: *App, source: c.VkBuffer, destination: c.VkBuffer, size: c.VkDeviceSize) !void {
        const allocate_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var command_buffer: c.VkCommandBuffer = null;
        try vkCheck(c.vkAllocateCommandBuffers(self.device, &allocate_info, &command_buffer));
        defer c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try vkCheck(c.vkBeginCommandBuffer(command_buffer, &begin_info));
        const region = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = size };
        c.vkCmdCopyBuffer(command_buffer, source, destination, 1, &region);
        try vkCheck(c.vkEndCommandBuffer(command_buffer));

        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        try vkCheck(c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, null));
        try vkCheck(c.vkQueueWaitIdle(self.graphics_queue));
    }

    fn createBuffer(self: *App, size: c.VkDeviceSize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory) !void {
        const buffer_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        try vkCheck(c.vkCreateBuffer(self.device, &buffer_info, null, buffer));
        errdefer c.vkDestroyBuffer(self.device, buffer.*, null);

        var mem_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buffer.*, &mem_requirements);
        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = try self.findMemoryType(mem_requirements.memoryTypeBits, properties),
        };
        try vkCheck(c.vkAllocateMemory(self.device, &alloc_info, null, memory));
        errdefer c.vkFreeMemory(self.device, memory.*, null);
        try vkCheck(c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0));
    }

    fn findMemoryType(self: *App, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);
        for (0..mem_properties.memoryTypeCount) |i_usize| {
            const i: u5 = @intCast(i_usize);
            if ((type_filter & (@as(u32, 1) << i)) != 0 and (mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
                return @intCast(i_usize);
            }
        }
        return error.NoSuitableMemoryType;
    }

    fn createCommandBuffers(self: *App) !void {
        self.command_buffers = try self.allocator.alloc(c.VkCommandBuffer, self.framebuffers.len);
        errdefer self.allocator.free(self.command_buffers);

        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.command_buffers.len),
        };
        try vkCheck(c.vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr));
        try self.recordCommandBuffers();
    }

    fn currentFrame(self: *App) SphericalFrame {
        const camera = self.world.frameCamera();
        const tracer = spherical_scene.Tracer.init(camera.pose, self.world.cube, self.world.fence);
        return .{
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .radius = tracer.radius,
            .tan_half_fov = camera.tan_half_fov,
            .origin = tracer.origin,
            .right = tracer.right,
            .up = tracer.up,
            .forward = tracer.forward,
        };
    }

    fn frameSize(self: *App) usize {
        return if (self.worlds_mode != null) @sizeOf(worlds_render.Frame) else @sizeOf(FrameGpu);
    }

    fn updateFrameBuffer(self: *App, image_index: usize) !void {
        const offset = self.frame_stride * image_index;
        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.frame_buffer_memory, offset, self.frameSize(), 0, &mapped));
        defer c.vkUnmapMemory(self.device, self.frame_buffer_memory);
        if (self.worlds_mode) |mode| {
            @as(*worlds_render.Frame, @ptrCast(@alignCast(mapped.?))).* = worlds_render.Frame.init(mode, @floatFromInt(self.swapchain_extent.width), @floatFromInt(self.swapchain_extent.height));
            return;
        }
        const frame = self.currentFrame();
        const gpu_frame = FrameGpu{
            .viewport = .{ frame.width, frame.height, frame.radius, frame.tan_half_fov },
            .origin = frame.origin,
            .right = frame.right,
            .up = frame.up,
            .forward = frame.forward,
        };
        @as(*FrameGpu, @ptrCast(@alignCast(mapped.?))).* = gpu_frame;
    }

    fn recordCommandBuffers(self: *App) !void {
        for (self.command_buffers, 0..) |command_buffer, i| {
            const begin_info = c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = 0,
                .pInheritanceInfo = null,
            };
            try vkCheck(c.vkBeginCommandBuffer(command_buffer, &begin_info));

            const clear_values = [_]c.VkClearValue{
                .{ .color = .{ .float32 = .{ 0.025, 0.025, 0.035, 1.0 } } },
                .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
            };
            const render_pass_info = c.VkRenderPassBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = null,
                .renderPass = self.render_pass,
                .framebuffer = self.framebuffers[i],
                .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
                .clearValueCount = 2,
                .pClearValues = &clear_values,
            };
            c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
            const spherical = self.worlds_mode == null or self.worlds_mode.? == .spherical;
            const pipeline = if (spherical) self.graphics_pipeline else self.worlds_pipeline;
            const layout = if (spherical) self.pipeline_layout else self.worlds_pipeline_layout;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            c.vkCmdBindDescriptorSets(
                command_buffer,
                c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                layout,
                0,
                1,
                &self.descriptor_sets[i],
                0,
                null,
            );
            c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
            if (spherical and self.mesh_pipeline != null and self.mesh_index_count > 0) {
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.mesh_pipeline);
                c.vkCmdBindDescriptorSets(
                    command_buffer,
                    c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    self.mesh_pipeline_layout,
                    0,
                    1,
                    &self.descriptor_sets[i],
                    0,
                    null,
                );
                const offsets = [_]c.VkDeviceSize{0};
                c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &self.vertex_buffer, &offsets);
                c.vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, c.VK_INDEX_TYPE_UINT32);
                c.vkCmdDrawIndexed(command_buffer, self.mesh_index_count, 1, 0, 0, 0);
            }
            if (spherical and self.worlds_mode != null) {
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.worlds_pipeline);
                c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.worlds_pipeline_layout, 0, 1, &self.descriptor_sets[i], 0, null);
                c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
            }
            c.vkCmdEndRenderPass(command_buffer);
            if (self.capture_path != null) self.recordCapture(command_buffer, self.swapchain_images[i]);
            try vkCheck(c.vkEndCommandBuffer(command_buffer));
        }
    }

    fn recreateCommandBuffers(self: *App) !void {
        if (self.command_buffers.len > 0) {
            c.vkFreeCommandBuffers(self.device, self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        try self.createCommandBuffers();
    }

    fn createSyncObjects(self: *App) !void {
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        for (0..max_frames_in_flight) |i| {
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available[i]));
            try vkCheck(c.vkCreateFence(self.device, &fence_info, null, &self.in_flight[i]));
        }
    }

    fn captureSize(self: *App) usize {
        return @as(usize, self.swapchain_extent.width) * self.swapchain_extent.height * 4;
    }

    fn recordCapture(self: *App, command_buffer: c.VkCommandBuffer, image: c.VkImage) void {
        var barrier = c.VkImageMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
        const region = c.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.swapchain_extent.width, .height = self.swapchain_extent.height, .depth = 1 },
        };
        c.vkCmdCopyImageToBuffer(command_buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.capture_buffer, 1, &region);
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    fn writeCapture(self: *App) !void {
        const bgra = switch (self.swapchain_image_format) {
            c.VK_FORMAT_B8G8R8A8_SRGB, c.VK_FORMAT_B8G8R8A8_UNORM => true,
            c.VK_FORMAT_R8G8B8A8_SRGB, c.VK_FORMAT_R8G8B8A8_UNORM => false,
            else => return error.UnsupportedCaptureFormat,
        };
        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.capture_buffer_memory, 0, self.captureSize(), 0, &mapped));
        defer c.vkUnmapMemory(self.device, self.capture_buffer_memory);
        const pixels = @as([*]const u8, @ptrCast(mapped.?))[0..self.captureSize()];
        const png = try png_capture.encode(self.allocator, self.swapchain_extent.width, self.swapchain_extent.height, pixels, bgra);
        defer self.allocator.free(png);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.capture_path.?, .data = png });
    }

    fn drawFrame(self: *App) !bool {
        try vkCheck(c.vkWaitForFences(self.device, 1, &self.in_flight[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));

        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available[self.current_frame], null, &image_index);
        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return false;
        }
        try vkCheckAllowSuboptimal(acquire_result);

        if (self.images_in_flight[image_index] != null) {
            try vkCheck(c.vkWaitForFences(self.device, 1, &self.images_in_flight[image_index], c.VK_TRUE, std.math.maxInt(u64)));
        }
        self.images_in_flight[image_index] = self.in_flight[self.current_frame];
        try self.updateFrameBuffer(image_index);
        try vkCheck(c.vkResetFences(self.device, 1, &self.in_flight[self.current_frame]));

        const wait_semaphores = [_]c.VkSemaphore{self.image_available[self.current_frame]};
        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]c.VkSemaphore{self.render_finished[image_index]};
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers[image_index],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };
        try vkCheck(c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight[self.current_frame]));

        const swapchains = [_]c.VkSwapchainKHR{self.swapchain};
        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        if (self.capture_path != null) {
            try vkCheck(c.vkWaitForFences(self.device, 1, &self.in_flight[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));
            try self.writeCapture();
        }
        const present_result = c.vkQueuePresentKHR(self.present_queue, &present_info);
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreateSwapchain();
        } else {
            try vkCheck(present_result);
        }

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
        return true;
    }

    fn reloadShadersIfChanged(self: *App) !bool {
        const new_vert_mtime = fileMtime(self.io, self.vert_path) catch return false;
        const new_frag_mtime = fileMtime(self.io, self.frag_path) catch return false;
        const new_worlds_mtime = if (self.worlds_mode != null) fileMtime(self.io, worlds_frag_path) catch return false else 0;
        if (new_vert_mtime == self.vert_mtime and new_frag_mtime == self.frag_mtime and new_worlds_mtime == self.worlds_frag_mtime) return false;

        std.debug.print("detected shader update; reloading...\n", .{});
        try vkCheck(c.vkDeviceWaitIdle(self.device));

        const new_bundle = self.createGraphicsPipeline() catch |err| {
            std.debug.print("shader reload failed: {s}; keeping previous pipeline\n", .{@errorName(err)});
            return false;
        };

        var new_worlds: ?PipelineBundle = null;
        if (self.worlds_mode != null) {
            new_worlds = self.createPipeline(self.vert_path, worlds_frag_path, false, true) catch |err| {
                c.vkDestroyPipeline(self.device, new_bundle.pipeline, null);
                c.vkDestroyPipelineLayout(self.device, new_bundle.layout, null);
                std.debug.print("worlds shader reload failed: {s}; keeping previous pipelines\n", .{@errorName(err)});
                return false;
            };
        }
        c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (new_worlds) |bundle| {
            c.vkDestroyPipeline(self.device, self.worlds_pipeline, null);
            c.vkDestroyPipelineLayout(self.device, self.worlds_pipeline_layout, null);
            self.worlds_pipeline = bundle.pipeline;
            self.worlds_pipeline_layout = bundle.layout;
        }
        self.graphics_pipeline = new_bundle.pipeline;
        self.pipeline_layout = new_bundle.layout;
        try self.recreateCommandBuffers();
        self.vert_mtime = new_vert_mtime;
        self.frag_mtime = new_frag_mtime;
        self.worlds_frag_mtime = new_worlds_mtime;
        std.debug.print("shader reload ok\n", .{});
        return true;
    }

    fn recreateSwapchain(self: *App) !void {
        var width: c_int = 0;
        var height: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &width, &height);
        while (width == 0 or height == 0) {
            c.glfwWaitEvents();
            c.glfwGetFramebufferSize(self.window, &width, &height);
        }

        try vkCheck(c.vkDeviceWaitIdle(self.device));
        self.cleanupSwapchain();
        try self.createSwapchain();
        try self.createFrameResources();
        try self.createImageViews();
        try self.createRenderPass();
        try self.createDepthResources();
        try self.createPipelines();
        try self.createFramebuffers();
        try self.createCommandBuffers();
    }

    fn cleanupSwapchain(self: *App) void {
        if (self.command_buffers.len > 0 and self.command_pool != null) {
            c.vkFreeCommandBuffers(self.device, self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.descriptor_pool = null;
        self.allocator.free(self.descriptor_sets);
        self.descriptor_sets = &.{};
        if (self.capture_buffer != null) c.vkDestroyBuffer(self.device, self.capture_buffer, null);
        if (self.capture_buffer_memory != null) c.vkFreeMemory(self.device, self.capture_buffer_memory, null);
        self.capture_buffer = null;
        self.capture_buffer_memory = null;
        if (self.frame_buffer != null) c.vkDestroyBuffer(self.device, self.frame_buffer, null);
        self.frame_buffer = null;
        if (self.frame_buffer_memory != null) c.vkFreeMemory(self.device, self.frame_buffer_memory, null);
        self.frame_buffer_memory = null;
        self.frame_stride = 0;
        self.allocator.free(self.images_in_flight);
        self.images_in_flight = &.{};
        for (self.render_finished) |semaphore| {
            if (semaphore != null) c.vkDestroySemaphore(self.device, semaphore, null);
        }
        self.allocator.free(self.render_finished);
        self.render_finished = &.{};

        for (self.framebuffers) |framebuffer| c.vkDestroyFramebuffer(self.device, framebuffer, null);
        self.allocator.free(self.framebuffers);
        self.framebuffers = &.{};

        if (self.graphics_pipeline != null) c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        if (self.worlds_pipeline != null) c.vkDestroyPipeline(self.device, self.worlds_pipeline, null);
        if (self.worlds_pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.worlds_pipeline_layout, null);
        self.worlds_pipeline = null;
        self.worlds_pipeline_layout = null;
        if (self.mesh_pipeline != null) c.vkDestroyPipeline(self.device, self.mesh_pipeline, null);
        if (self.mesh_pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.mesh_pipeline_layout, null);
        self.graphics_pipeline = null;
        self.mesh_pipeline = null;
        self.mesh_pipeline_layout = null;
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.pipeline_layout = null;
        if (self.render_pass != null) c.vkDestroyRenderPass(self.device, self.render_pass, null);
        self.render_pass = null;
        if (self.depth_image_view != null) c.vkDestroyImageView(self.device, self.depth_image_view, null);
        self.depth_image_view = null;
        if (self.depth_image != null) c.vkDestroyImage(self.device, self.depth_image, null);
        self.depth_image = null;
        if (self.depth_image_memory != null) c.vkFreeMemory(self.device, self.depth_image_memory, null);
        self.depth_image_memory = null;

        for (self.swapchain_image_views) |image_view| c.vkDestroyImageView(self.device, image_view, null);
        self.allocator.free(self.swapchain_image_views);
        self.swapchain_image_views = &.{};
        self.allocator.free(self.swapchain_images);
        self.swapchain_images = &.{};
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
    }
};

fn fillObjectBlock(block: *ObjectGpuBlock, file: object_scene.File) !void {
    try file.validateGpuCapacity(MaxObjects, MaxMaterials);
    for (file.objects, 0..) |object, object_index| {
        const base = object_index * 6;
        for (object.faces, 0..) |face, face_index| {
            const normal = object.transformNormal(face.normal);
            block.normals[base + face_index] = normal.coeffsArray();
            block.meta[base + face_index] = .{
                if (face.positive) 1.0 else 0.0,
                file.materials[face.material].tone,
                @floatFromInt(face.material),
                0.0,
            };
        }
        if (object.bound) |bound| {
            block.bounds[object_index] = object.transformPoint(bound.center).coeffsArray();
            block.meta[base][3] = bound.cos_radius;
        } else {
            block.meta[base][3] = -1.0;
        }
    }
    for (file.materials, 0..) |material, index| block.colors[index] = material.color;
}

fn worldKeyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;
    if (action != c.GLFW_PRESS) return;
    const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
    app.requested_world = switch (key) {
        c.GLFW_KEY_1, c.GLFW_KEY_KP_1 => .euclidean,
        c.GLFW_KEY_2, c.GLFW_KEY_KP_2 => .isometric,
        c.GLFW_KEY_3, c.GLFW_KEY_KP_3 => .spherical,
        c.GLFW_KEY_4, c.GLFW_KEY_KP_4 => .hyperbolic,
        c.GLFW_KEY_TAB => @fromBackingInt(@as(u2, @intCast((@as(u32, @backingInt(app.requested_world orelse std.meta.activeTag(app.worlds_mode.?))) + 1) % 4))),
        else => app.requested_world,
    };
}

fn worldScrollCallback(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.c) void {
    _ = x;
    const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
    app.scroll_delta += @floatCast(y);
}

fn worldMouseCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    if (button != c.GLFW_MOUSE_BUTTON_LEFT or action != c.GLFW_PRESS) return;
    const app: *App = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window) orelse return));
    var x: f64 = 0;
    var y: f64 = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetCursorPos(window, &x, &y);
    c.glfwGetWindowSize(window, &width, &height);
    if (width <= 0 or height <= 0) return;
    const px: f32 = @floatCast(x * @as(f64, @floatFromInt(app.swapchain_extent.width)) / @as(f64, @floatFromInt(width)));
    const py: f32 = @floatCast(y * @as(f64, @floatFromInt(app.swapchain_extent.height)) / @as(f64, @floatFromInt(height)));
    if (worlds_render.selectorKind(px, py)) |kind| app.requested_world = kind;
}

fn framebufferResizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    _ = width;
    _ = height;
    const user_ptr = c.glfwGetWindowUserPointer(window);
    if (user_ptr) |ptr| {
        const app: *App = @ptrCast(@alignCast(ptr));
        app.framebuffer_resized = true;
    }
}

fn chooseSwapSurfaceFormat(formats: []const c.VkSurfaceFormatKHR) c.VkSurfaceFormatKHR {
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) return format;
    }
    return formats[0];
}

fn chooseSwapPresentMode(present_modes: []const c.VkPresentModeKHR) c.VkPresentModeKHR {
    for (present_modes) |mode| {
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) return mode;
    }
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(window: ?*c.GLFWwindow, capabilities: c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) return capabilities.currentExtent;

    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(window, &width, &height);
    return .{
        .width = std.math.clamp(@as(u32, @intCast(width)), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
        .height = std.math.clamp(@as(u32, @intCast(height)), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
    };
}

fn readSpirvWords(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u32 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidSpirvSize;
    const words = try allocator.alloc(u32, bytes.len / @sizeOf(u32));
    @memcpy(std.mem.sliceAsBytes(words), bytes);
    return words;
}

fn fileMtime(io: std.Io, path: []const u8) !i128 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return stat.mtime.nanoseconds;
}

fn vkCheck(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return vkError(result);
}

fn vkCheckAllowSuboptimal(result: c.VkResult) !void {
    if (result == c.VK_SUCCESS or result == c.VK_SUBOPTIMAL_KHR) return;
    return vkError(result);
}

fn vkError(result: c.VkResult) anyerror {
    std.debug.print("Vulkan error: {d}\n", .{result});
    return error.VulkanError;
}

pub fn main(init: std.process.Init) !void {
    try runFrontend(init, false);
}

pub fn runWorlds(init: std.process.Init) !void {
    try runFrontend(init, true);
}

fn worldKind(name: []const u8) !space.Kind {
    inline for (@typeInfo(space.Kind).@"enum".field_names) |field| {
        if (std.mem.eql(u8, name, field)) return @field(space.Kind, field);
    }
    return error.InvalidWorld;
}

fn runFrontend(init: std.process.Init, worlds: bool) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const vert_path = if (worlds) "zig-out/shaders/spherical_ground.vert.spv" else args.next() orelse default_vert_path;
    const frag_path = if (worlds) "zig-out/shaders/spherical_ground.frag.spv" else args.next() orelse default_frag_path;
    const mesh_vert_path = if (worlds) "zig-out/shaders/spherical_mesh.vert.spv" else args.next();
    const mesh_frag_path = if (worlds) "zig-out/shaders/spherical_mesh.frag.spv" else args.next();
    var benchmark_frames: u32 = 0;
    var kind: space.Kind = .euclidean;
    if (worlds) {
        if (init.environ_map.get("ZMATH_DEMO_WORLD")) |value| kind = try worldKind(value);
        if (init.environ_map.get("ZMATH_DEMO_FRAMES")) |value| benchmark_frames = try std.fmt.parseInt(u32, value, 10);
    }
    var compare = false;
    var pose: ?[3]f32 = null;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--benchmark")) {
            benchmark_frames = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArgument, 10);
        } else if (std.mem.eql(u8, flag, "--compare")) {
            compare = true;
        } else if (worlds and std.mem.eql(u8, flag, "--world")) {
            kind = try worldKind(args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, flag, "--pose")) {
            pose = .{
                try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument),
                try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument),
                try std.fmt.parseFloat(f32, args.next() orelse return error.InvalidArgument),
            };
        } else return error.InvalidArgument;
    }
    var world = spherical_scene.Scene.init();
    var mode: ?space.Mode = if (worlds) space.Mode.init(kind) else null;
    const capture_path = init.environ_map.get("ZMATH_DEMO_CAPTURE");
    if (capture_path != null) {
        if (mode) |*selected| {
            const defaults = space.Mode.captureDefaults(kind);
            const walk = if (init.environ_map.get("ZMATH_DEMO_WALK")) |value| try std.fmt.parseFloat(f32, value) else defaults.walk;
            const pitch = if (init.environ_map.get("ZMATH_DEMO_PITCH")) |value| try std.fmt.parseFloat(f32, value) else defaults.pitch;
            selected.applyCapture(walk, pitch);
        }
        benchmark_frames = 1;
    }
    if (pose) |values| {
        if (mode) |*selected| {
            selected.* = space.Mode.init(kind);
            selected.applyCapture(values[0], 0);
            switch (selected.*) {
                .euclidean => |*view| view.* = view.yawBy(values[1]).pitchBy(-values[2]),
                .isometric => |*view| view.* = view.yawBy(values[1]),
                .spherical => |*sphere| {
                    if (values[1] != 0) sphere.yaw(values[1]);
                    if (values[2] != 0) sphere.pitch(values[2]);
                },
                .hyperbolic => |*view| {
                    if (values[1] != 0) view.* = view.yaw(values[1]);
                    if (values[2] != 0) view.* = view.pitch(-values[2]);
                },
            }
        } else {
            world.walkForward(values[0]);
            if (values[1] != 0) world.yaw(values[1]);
            if (values[2] != 0) world.pitch(values[2]);
        }
    }
    var app = try App.init(init.gpa, init.io, vert_path, frag_path, mesh_vert_path, mesh_frag_path, benchmark_frames, world, compare, mode, capture_path);
    defer app.deinit();
    try app.run();
}
