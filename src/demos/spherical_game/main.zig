const std = @import("std");
const scene = @import("scene.zig");
const object_scene = @import("object_scene.zig");

const rl = @cImport({
    @cInclude("stdlib.h");
    @cInclude("raylib.h");
    @cInclude("rlgl.h");
});

const render_width = 960;
const render_height = 540;

const default_capture_walk: f32 = scene.default_cube_distance + std.math.pi * scene.default_radius - 0.15;
const default_capture_pitch: f32 = -1.4;
const default_object_path: [*:0]const u8 = "assets/spherical/world.s3obj.json";
const spherical_shader = @import("spherical_shader");
const spherical_fragment_source = spherical_shader.fragment;

const max_object_count = 64;
const max_object_faces = max_object_count * 6;
const max_object_materials = 16;
const gl_uniform_buffer: c_uint = 0x8A11;
const gl_static_draw: c_uint = 0x88E4;
const gl_texture0: c_uint = 0x84C0;
const gl_texture_2d: c_uint = 0x0DE1;

const GlApi = struct {
    gen_buffers: *const fn (c_int, *c_uint) callconv(.c) void,
    delete_buffers: *const fn (c_int, *const c_uint) callconv(.c) void,
    bind_buffer: *const fn (c_uint, c_uint) callconv(.c) void,
    buffer_data: *const fn (c_uint, isize, ?*const anyopaque, c_uint) callconv(.c) void,
    bind_buffer_base: *const fn (c_uint, c_uint, c_uint) callconv(.c) void,
    get_uniform_block_index: *const fn (c_uint, [*:0]const u8) callconv(.c) c_uint,
    uniform_block_binding: *const fn (c_uint, c_uint, c_uint) callconv(.c) void,
    active_texture: *const fn (c_uint) callconv(.c) void,
    bind_texture: *const fn (c_uint, c_uint) callconv(.c) void,
    uniform_1i: *const fn (c_int, c_int) callconv(.c) void,

    fn init() ?GlApi {
        return .{
            .gen_buffers = @ptrCast(rl.rlGetProcAddress("glGenBuffers") orelse return null),
            .delete_buffers = @ptrCast(rl.rlGetProcAddress("glDeleteBuffers") orelse return null),
            .bind_buffer = @ptrCast(rl.rlGetProcAddress("glBindBuffer") orelse return null),
            .buffer_data = @ptrCast(rl.rlGetProcAddress("glBufferData") orelse return null),
            .bind_buffer_base = @ptrCast(rl.rlGetProcAddress("glBindBufferBase") orelse return null),
            .get_uniform_block_index = @ptrCast(rl.rlGetProcAddress("glGetUniformBlockIndex") orelse return null),
            .uniform_block_binding = @ptrCast(rl.rlGetProcAddress("glUniformBlockBinding") orelse return null),
            .active_texture = @ptrCast(rl.rlGetProcAddress("glActiveTexture") orelse return null),
            .bind_texture = @ptrCast(rl.rlGetProcAddress("glBindTexture") orelse return null),
            .uniform_1i = @ptrCast(rl.rlGetProcAddress("glUniform1i") orelse return null),
        };
    }
};

const ObjectGpuBlock = extern struct {
    normals: [max_object_faces * 4]f32,
    meta: [max_object_faces * 4]f32,
    colors: [max_object_materials * 4]f32,
    bounds: [max_object_count * 4]f32,
};

const MeshRenderer = struct {
    model: rl.Model,
    shader: rl.Shader,
    resolution: c_int,
    tan_half_fov: c_int,
    world_radius: c_int,
    origin: c_int,
    right: c_int,
    up: c_int,
    forward: c_int,
    mesh_center: c_int,
    mesh_basis_x: c_int,
    mesh_basis_y: c_int,
    mesh_basis_z: c_int,
    center: [4]f32 = .{ 1, 0, 0, 0 },
    basis_x: [4]f32 = .{ 0, 1, 0, 0 },
    // raylib's glTF loader exposes the glTF Y-up frame: X lateral, Y up,
    // Z forward in the local tangent frame.
    basis_y: [4]f32 = .{ 0, 0, 1, 0 },
    basis_z: [4]f32 = .{ 0, 0, 0, 1 },

    fn init(path: [*:0]const u8) ?MeshRenderer {
        const model = rl.LoadModel(path);
        if (model.meshCount == 0) {
            std.debug.print("mesh scene failed to load: {s}\n", .{path});
            return null;
        }
        const shader = rl.LoadShaderFromMemory(spherical_shader.mesh_vertex.ptr, spherical_shader.mesh_fragment.ptr);
        if (!rl.IsShaderValid(shader)) {
            std.debug.print("GPU spherical mesh shader failed to compile\n", .{});
            rl.UnloadModel(model);
            return null;
        }
        shader.locs[rl.SHADER_LOC_MATRIX_MODEL] = rl.GetShaderLocation(shader, "matModel");
        shader.locs[rl.SHADER_LOC_MAP_ALBEDO] = rl.GetShaderLocation(shader, "texture0");
        shader.locs[rl.SHADER_LOC_COLOR_DIFFUSE] = rl.GetShaderLocation(shader, "colDiffuse");
        const materials = model.materials[0..@intCast(model.materialCount)];
        for (materials) |*material| material.shader = shader;

        return .{
            .model = model,
            .shader = shader,
            .resolution = rl.GetShaderLocation(shader, "u_resolution"),
            .tan_half_fov = rl.GetShaderLocation(shader, "u_tan_half_fov"),
            .world_radius = rl.GetShaderLocation(shader, "u_world_radius"),
            .origin = rl.GetShaderLocation(shader, "u_origin"),
            .right = rl.GetShaderLocation(shader, "u_right"),
            .up = rl.GetShaderLocation(shader, "u_up"),
            .forward = rl.GetShaderLocation(shader, "u_forward"),
            .mesh_center = rl.GetShaderLocation(shader, "u_mesh_center"),
            .mesh_basis_x = rl.GetShaderLocation(shader, "u_mesh_basis_x"),
            .mesh_basis_y = rl.GetShaderLocation(shader, "u_mesh_basis_y"),
            .mesh_basis_z = rl.GetShaderLocation(shader, "u_mesh_basis_z"),
        };
    }

    fn render(self: *MeshRenderer, world: *scene.Scene, width: c_int, height: c_int) void {
        const tracer = world.tracer();
        const camera = world.frameCamera();
        setVec2(self.shader, self.resolution, .{ @floatFromInt(width), @floatFromInt(height) });
        setFloat(self.shader, self.tan_half_fov, camera.tan_half_fov);
        setFloat(self.shader, self.world_radius, tracer.radius);
        setPoint(self.shader, self.origin, tracer.origin);
        setPoint(self.shader, self.right, tracer.right);
        setPoint(self.shader, self.up, tracer.up);
        setPoint(self.shader, self.forward, tracer.forward);
        setVec4(self.shader, self.mesh_center, self.center);
        setVec4(self.shader, self.mesh_basis_x, self.basis_x);
        setVec4(self.shader, self.mesh_basis_y, self.basis_y);
        setVec4(self.shader, self.mesh_basis_z, self.basis_z);

        const camera3d = rl.Camera3D{
            .position = .{ .x = 0, .y = 0, .z = 1 },
            .target = .{ .x = 0, .y = 0, .z = 0 },
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .fovy = 90,
            .projection = rl.CAMERA_PERSPECTIVE,
        };
        rl.BeginMode3D(camera3d);
        // The projected S³ chart can reverse winding across the view, so
        // culling and the Euclidean depth buffer cannot decide visibility.
        rl.rlDisableDepthTest();
        rl.rlDisableBackfaceCulling();
        for (0..@intCast(self.model.meshCount)) |mesh_index| {
            const material_index: usize = @intCast(self.model.meshMaterial[mesh_index]);
            var material = self.model.materials[material_index];
            material.shader = self.shader;
            rl.DrawMesh(self.model.meshes[mesh_index], material, self.model.transform);
        }
        rl.rlEnableBackfaceCulling();
        rl.rlEnableDepthTest();
        rl.EndMode3D();
    }

    fn deinit(self: *MeshRenderer) void {
        rl.UnloadModel(self.model);
        rl.UnloadShader(self.shader);
    }
};

const GpuRenderer = struct {
    shader: rl.Shader,
    composite_shader: rl.Shader,
    composite_mesh_texture: c_int,
    composite_mesh_enabled: c_int,
    analytic_target: rl.RenderTexture2D,
    mesh_target: rl.RenderTexture2D,
    resolution: c_int,
    tan_half_fov: c_int,
    origin: c_int,
    right: c_int,
    up: c_int,
    forward: c_int,
    ground_a: c_int,
    world_radius: c_int,
    object_count: c_int,
    gl: GlApi,
    object_buffer: c_uint,

    fn init(width: c_int, height: c_int) ?GpuRenderer {
        const gl = GlApi.init() orelse {
            std.debug.print("OpenGL buffer API unavailable\n", .{});
            return null;
        };
        const shader = rl.LoadShaderFromMemory(null, spherical_fragment_source.ptr);
        if (!rl.IsShaderValid(shader)) {
            std.debug.print("GPU spherical shader failed to compile\n", .{});
            return null;
        }
        var object_buffer: c_uint = 0;
        gl.gen_buffers(1, &object_buffer);
        gl.bind_buffer(gl_uniform_buffer, object_buffer);
        gl.buffer_data(gl_uniform_buffer, @sizeOf(ObjectGpuBlock), null, gl_static_draw);
        gl.bind_buffer_base(gl_uniform_buffer, 0, object_buffer);
        const block_index = gl.get_uniform_block_index(shader.id, "ObjectBlock");
        if (block_index == std.math.maxInt(c_uint)) {
            std.debug.print("ObjectBlock missing from GPU shader\n", .{});
            gl.delete_buffers(1, &object_buffer);
            rl.UnloadShader(shader);
            return null;
        }
        gl.uniform_block_binding(shader.id, block_index, 0);

        const composite_shader = rl.LoadShaderFromMemory(null, spherical_shader.composite_fragment.ptr);
        if (!rl.IsShaderValid(composite_shader)) {
            std.debug.print("GPU spherical compositor failed to compile\n", .{});
            gl.delete_buffers(1, &object_buffer);
            rl.UnloadShader(shader);
            return null;
        }
        const analytic_target = rl.LoadRenderTexture(width, height);
        const mesh_target = rl.LoadRenderTexture(width, height);

        return .{
            .shader = shader,
            .composite_shader = composite_shader,
            .composite_mesh_texture = rl.GetShaderLocation(composite_shader, "u_mesh_texture"),
            .composite_mesh_enabled = rl.GetShaderLocation(composite_shader, "u_mesh_enabled"),
            .analytic_target = analytic_target,
            .mesh_target = mesh_target,
            .resolution = rl.GetShaderLocation(shader, "u_resolution"),
            .tan_half_fov = rl.GetShaderLocation(shader, "u_tan_half_fov"),
            .origin = rl.GetShaderLocation(shader, "u_origin"),
            .right = rl.GetShaderLocation(shader, "u_right"),
            .up = rl.GetShaderLocation(shader, "u_up"),
            .forward = rl.GetShaderLocation(shader, "u_forward"),
            .ground_a = rl.GetShaderLocation(shader, "u_ground_a"),
            .world_radius = rl.GetShaderLocation(shader, "u_world_radius"),
            .object_count = rl.GetShaderLocation(shader, "u_object_count"),
            .gl = gl,
            .object_buffer = object_buffer,
        };
    }

    fn uploadObjects(self: *GpuRenderer, file: object_scene.File) !void {
        try file.validateGpuCapacity(max_object_count, max_object_materials);

        var block: ObjectGpuBlock = undefined;
        @memset(std.mem.asBytes(&block), 0);
        const object_count = file.objects.len;
        for (file.objects[0..object_count], 0..) |object, object_index| {
            const base = object_index * 24;
            for (object.faces, 0..) |face, face_index| {
                const face_base = base + face_index * 4;
                const normal = object.transformNormal(face.normal);
                block.normals[face_base + 0] = normal[0];
                block.normals[face_base + 1] = normal[1];
                block.normals[face_base + 2] = normal[2];
                block.normals[face_base + 3] = normal[3];
                block.meta[face_base + 0] = if (face.positive) 1.0 else 0.0;
                block.meta[face_base + 1] = file.materials[face.material].tone;
                block.meta[face_base + 2] = @floatFromInt(face.material);
            }
            if (object.bound) |bound| {
                const bound_base = object_index * 4;
                const center = object.transformPoint(bound.center);
                @memcpy(block.bounds[bound_base..][0..4], &center);
                block.meta[object_index * 24 + 3] = bound.cos_radius;
            } else {
                block.meta[object_index * 24 + 3] = -1.0;
            }
        }
        const material_count = file.materials.len;
        for (file.materials[0..material_count], 0..) |material, i| {
            @memcpy(block.colors[i * 4 ..][0..4], &material.color);
        }
        self.gl.bind_buffer(gl_uniform_buffer, self.object_buffer);
        self.gl.buffer_data(gl_uniform_buffer, @sizeOf(ObjectGpuBlock), @ptrCast(&block), gl_static_draw);
        self.gl.bind_buffer_base(gl_uniform_buffer, 0, self.object_buffer);
        setInt(self.shader, self.object_count, @intCast(object_count));
    }

    fn present(self: *GpuRenderer, mesh_enabled: bool) void {
        rl.BeginShaderMode(self.composite_shader);
        setFloat(self.composite_shader, self.composite_mesh_enabled, if (mesh_enabled) 1.0 else 0.0);
        self.gl.active_texture(gl_texture0 + 1);
        self.gl.bind_texture(gl_texture_2d, self.mesh_target.texture.id);
        self.gl.uniform_1i(self.composite_mesh_texture, 1);
        self.gl.active_texture(gl_texture0);
        rl.DrawTexturePro(
            self.analytic_target.texture,
            .{ .x = 0, .y = 0, .width = @floatFromInt(self.analytic_target.texture.width), .height = -@as(f32, @floatFromInt(self.analytic_target.texture.height)) },
            .{ .x = 0, .y = 0, .width = @floatFromInt(rl.GetScreenWidth()), .height = @floatFromInt(rl.GetScreenHeight()) },
            .{ .x = 0, .y = 0 },
            0,
            color(255, 255, 255, 255),
        );
        rl.EndShaderMode();
    }

    fn resize(self: *GpuRenderer, width: c_int, height: c_int) void {
        if (self.analytic_target.texture.width == width and self.analytic_target.texture.height == height) return;
        const analytic_target = rl.LoadRenderTexture(width, height);
        const mesh_target = rl.LoadRenderTexture(width, height);
        rl.UnloadRenderTexture(self.analytic_target);
        rl.UnloadRenderTexture(self.mesh_target);
        self.analytic_target = analytic_target;
        self.mesh_target = mesh_target;
    }

    fn deinit(self: *GpuRenderer) void {
        self.gl.delete_buffers(1, &self.object_buffer);
        rl.UnloadRenderTexture(self.analytic_target);
        rl.UnloadRenderTexture(self.mesh_target);
        rl.UnloadShader(self.composite_shader);
        rl.UnloadShader(self.shader);
    }
};

pub fn main() void {
    const capture_path = rl.getenv("ZMATH_DEMO_CAPTURE");
    const capture = capture_path != null;
    var flags: c_uint = rl.FLAG_WINDOW_RESIZABLE;
    if (capture) {
        flags |= rl.FLAG_WINDOW_HIDDEN;
    } else {
        flags |= rl.FLAG_VSYNC_HINT;
    }
    rl.SetConfigFlags(flags);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(1280, 720, "zmath demo: spherical game");
    defer rl.CloseWindow();

    const object_path: [*:0]const u8 = if (rl.getenv("ZMATH_DEMO_OBJECT")) |path| @ptrCast(path) else default_object_path;
    const object_text = rl.LoadFileText(object_path);
    if (object_text == null) {
        std.debug.print("object scene failed to load: {s}\n", .{object_path});
        return;
    }
    defer rl.UnloadFileText(object_text);
    const object_source: [*:0]const u8 = @ptrCast(object_text);
    const object_file = object_scene.parse(std.heap.page_allocator, std.mem.span(object_source)) catch |err| {
        std.debug.print("object scene failed to parse: {s}\n", .{@errorName(err)});
        return;
    };
    defer object_file.deinit();

    var world = scene.Scene.init();
    if (capture) {
        const walk = if (rl.getenv("ZMATH_DEMO_WALK")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch default_capture_walk
        else
            default_capture_walk;
        const pitch = if (rl.getenv("ZMATH_DEMO_PITCH")) |value|
            std.fmt.parseFloat(f32, std.mem.span(value)) catch default_capture_pitch
        else
            default_capture_pitch;
        world.walkForward(walk);
        if (rl.getenv("ZMATH_DEMO_YAW")) |value| {
            const yaw = std.fmt.parseFloat(f32, std.mem.span(value)) catch 0.0;
            if (yaw != 0.0) world.yaw(yaw);
        }
        if (pitch != 0.0) world.pitch(pitch);
    }

    var gpu = GpuRenderer.init(rl.GetRenderWidth(), rl.GetRenderHeight()) orelse return;
    defer gpu.deinit();
    gpu.uploadObjects(object_file.value) catch |err| {
        std.debug.print("object scene exceeds GPU capacity: {s}\n", .{@errorName(err)});
        return;
    };

    var mesh_renderer: ?MeshRenderer = null;
    if (rl.getenv("ZMATH_DEMO_MESH")) |path| {
        mesh_renderer = MeshRenderer.init(@ptrCast(path)) orelse return;
    }
    defer if (mesh_renderer) |*mesh| mesh.deinit();

    // Optional frame cap for headless perf measurement.
    const frame_cap: ?u32 = if (rl.getenv("ZMATH_DEMO_FRAMES")) |value|
        std.fmt.parseInt(u32, std.mem.span(value), 10) catch null
    else
        null;
    var frames: u32 = 0;

    while (!rl.WindowShouldClose()) : (frames += 1) {
        if (frame_cap) |cap| {
            if (frames >= cap) break;
        }
        if (!capture) {
            const dt = @min(rl.GetFrameTime(), 0.05);
            update(&world, dt);
        }

        gpu.resize(rl.GetRenderWidth(), rl.GetRenderHeight());
        rl.BeginDrawing();
        renderFrame(&world, &gpu);
        rl.BeginTextureMode(gpu.mesh_target);
        rl.rlClearColor(0, 0, 0, 0);
        rl.rlClearScreenBuffers();
        rl.rlDisableColorBlend();
        if (mesh_renderer) |*mesh| mesh.render(&world, gpu.mesh_target.texture.width, gpu.mesh_target.texture.height);
        rl.rlEnableColorBlend();
        rl.EndTextureMode();
        rl.ClearBackground(color(4, 6, 10, 255));
        gpu.present(mesh_renderer != null);
        drawHud(&world);
        rl.EndDrawing();

        if (capture) {
            rl.TakeScreenshot(capture_path.?);
            break;
        }
    }
}

fn update(world: *scene.Scene, dt: f32) void {
    if (rl.IsKeyPressed(rl.KEY_R)) world.* = scene.Scene.init();

    // Pace movement by the conjugate gap: the reverse-perspective morph
    // compresses into a small walk window around it, so ease off there.
    const speed_scale = scene.Scene.speedScaleForGap(world.conjugateGap());
    const move_speed: f32 = 2.2 * speed_scale;
    const look_speed: f32 = 1.35;
    if (rl.IsKeyDown(rl.KEY_S)) world.walkForward(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_W)) world.walkForward(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_D)) world.strafeRight(move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_A)) world.strafeRight(-move_speed * dt);
    if (rl.IsKeyDown(rl.KEY_LEFT)) world.yaw(look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_RIGHT)) world.yaw(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_UP)) world.pitch(-look_speed * dt);
    if (rl.IsKeyDown(rl.KEY_DOWN)) world.pitch(look_speed * dt);
}

fn setFloat(shader: rl.Shader, location: c_int, value: f32) void {
    var v = value;
    rl.SetShaderValue(shader, location, &v, rl.SHADER_UNIFORM_FLOAT);
}

fn setInt(shader: rl.Shader, location: c_int, value: c_int) void {
    var v = value;
    rl.SetShaderValue(shader, location, &v, rl.SHADER_UNIFORM_INT);
}

fn setVec2(shader: rl.Shader, location: c_int, value: [2]f32) void {
    var v = value;
    rl.SetShaderValue(shader, location, &v, rl.SHADER_UNIFORM_VEC2);
}

fn setVec4(shader: rl.Shader, location: c_int, value: [4]f32) void {
    var v = value;
    rl.SetShaderValue(shader, location, &v, rl.SHADER_UNIFORM_VEC4);
}

fn setPoint(shader: rl.Shader, location: c_int, value: anytype) void {
    setVec4(shader, location, value.coeffsArray());
}

fn renderFrame(world: *scene.Scene, gpu: *GpuRenderer) void {
    rl.BeginTextureMode(gpu.analytic_target);
    rl.ClearBackground(color(4, 6, 10, 0));
    rl.rlDisableColorBlend();

    const tracer = world.tracer();
    const camera = world.frameCamera();

    const target_width = gpu.analytic_target.texture.width;
    const target_height = gpu.analytic_target.texture.height;
    setVec2(gpu.shader, gpu.resolution, .{ @floatFromInt(target_width), @floatFromInt(target_height) });
    setFloat(gpu.shader, gpu.tan_half_fov, camera.tan_half_fov);
    setPoint(gpu.shader, gpu.origin, tracer.origin);
    setPoint(gpu.shader, gpu.right, tracer.right);
    setPoint(gpu.shader, gpu.up, tracer.up);
    setPoint(gpu.shader, gpu.forward, tracer.forward);

    setFloat(gpu.shader, gpu.ground_a, tracer.ground_a);
    setFloat(gpu.shader, gpu.world_radius, tracer.radius);

    rl.BeginShaderMode(gpu.shader);
    rl.DrawRectangle(0, 0, target_width, target_height, color(255, 255, 255, 255));
    rl.EndShaderMode();
    rl.rlEnableColorBlend();
    rl.EndTextureMode();
}

fn drawHud(world: *scene.Scene) void {
    const stats = scene.Scene.sampleFrame(world.*, 64, 36);

    rl.DrawRectangle(16, 16, 660, 92, color(4, 7, 12, 205));
    rl.DrawRectangleLines(16, 16, 660, 92, color(130, 155, 180, 110));
    rl.DrawText("S3 spherical-game demo (stereographic ray trace)", 30, 27, 22, color(246, 247, 241, 255));
    rl.DrawText("W/S move, A/D strafe, arrows look, R reset. Walk S past the far side, then look up: the roof centers and the walls wrap the sky.", 30, 57, 16, color(190, 204, 220, 235));

    var buffer: [192]u8 = undefined;
    const status = if (world.cubeBearingForwardCosine() < 0.0)
        std.fmt.bufPrintZ(
            &buffer,
            "the cube is behind you - turn around   faces {d}/5   frame cube {d:.0}%   {d} fps",
            .{ stats.visibleFaceCount(), stats.cubeFraction() * 100.0, rl.GetFPS() },
        ) catch return
    else
        std.fmt.bufPrintZ(
            &buffer,
            "cube distance {d:.2} / {d:.2}   faces {d}/5   frame cube {d:.0}%   {d} fps",
            .{
                world.distanceToCube(),
                std.math.pi * world.radius,
                stats.visibleFaceCount(),
                stats.cubeFraction() * 100.0,
                rl.GetFPS(),
            },
        ) catch return;
    rl.DrawText(status, 30, 82, 16, color(150, 174, 201, 230));
}

fn color(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
