const std = @import("std");

const c = @import("vulkan_glfw");

const window_width = 960;
const window_height = 640;
const max_frames_in_flight = 2;

const default_vert_path = "zig-out/shaders/vga_passthrough_raw.vert.spv";
const default_frag_path = "zig-out/shaders/vga_passthrough_raw.frag.spv";

const Vertex = extern struct {
    pos: [2]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ -0.85, -0.85 } },
    .{ .pos = .{ 0.85, -0.85 } },
    .{ .pos = .{ 0.0, 0.85 } },
};

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

    render_pass: c.VkRenderPass = null,
    pipeline_layout: c.VkPipelineLayout = null,
    graphics_pipeline: c.VkPipeline = null,

    command_pool: c.VkCommandPool = null,
    command_buffers: []c.VkCommandBuffer = &.{},

    vertex_buffer: c.VkBuffer = null,
    vertex_buffer_memory: c.VkDeviceMemory = null,

    image_available: [max_frames_in_flight]c.VkSemaphore = [_]c.VkSemaphore{null} ** max_frames_in_flight,
    render_finished: [max_frames_in_flight]c.VkSemaphore = [_]c.VkSemaphore{null} ** max_frames_in_flight,
    in_flight: [max_frames_in_flight]c.VkFence = [_]c.VkFence{null} ** max_frames_in_flight,
    current_frame: usize = 0,

    framebuffer_resized: bool = false,
    vert_path: []const u8 = default_vert_path,
    frag_path: []const u8 = default_frag_path,
    vert_mtime: i128 = 0,
    frag_mtime: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, vert_path: []const u8, frag_path: []const u8) !App {
        var app = App{
            .allocator = allocator,
            .io = io,
            .vert_path = vert_path,
            .frag_path = frag_path,
        };
        errdefer app.deinit();

        try app.initWindow();
        try app.initVulkan();
        app.vert_mtime = fileMtime(app.io, vert_path) catch 0;
        app.frag_mtime = fileMtime(app.io, frag_path) catch 0;
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.device != null) _ = c.vkDeviceWaitIdle(self.device);

        self.cleanupSwapchain();

        if (self.vertex_buffer != null) c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        if (self.vertex_buffer_memory != null) c.vkFreeMemory(self.device, self.vertex_buffer_memory, null);

        for (0..max_frames_in_flight) |i| {
            if (self.image_available[i] != null) c.vkDestroySemaphore(self.device, self.image_available[i], null);
            if (self.render_finished[i] != null) c.vkDestroySemaphore(self.device, self.render_finished[i], null);
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
        std.debug.print("shader playground\n", .{});
        std.debug.print("  vertex:   {s}\n", .{self.vert_path});
        std.debug.print("  fragment: {s}\n", .{self.frag_path});
        std.debug.print("Run this in another terminal for live SPIR-V rebuilds:\n", .{});
        std.debug.print("  zig build --watch spirv-raw     # driver-valid raw baseline\n", .{});
        std.debug.print("  zig build --watch spirv-vga     # GA shaders, currently useful for compiler/driver debugging\n\n", .{});

        while (c.glfwWindowShouldClose(self.window) == c.GLFW_FALSE) {
            c.glfwPollEvents();
            try self.reloadShadersIfChanged();
            try self.drawFrame();
        }
        try vkCheck(c.vkDeviceWaitIdle(self.device));
    }

    fn initWindow(self: *App) !void {
        if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
        if (c.glfwVulkanSupported() != c.GLFW_TRUE) return error.GlfwVulkanUnavailable;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
        self.window = c.glfwCreateWindow(window_width, window_height, "zmath SPIR-V playground", null, null) orelse return error.GlfwCreateWindowFailed;
        c.glfwSetWindowUserPointer(self.window, self);
        _ = c.glfwSetFramebufferSizeCallback(self.window, framebufferResizeCallback);
    }

    fn initVulkan(self: *App) !void {
        try self.createInstance();
        try self.createSurface();
        try self.pickPhysicalDevice();
        try self.createLogicalDevice();
        try self.createSwapchain();
        try self.createImageViews();
        try self.createRenderPass();
        const bundle = try self.createGraphicsPipeline();
        self.pipeline_layout = bundle.layout;
        self.graphics_pipeline = bundle.pipeline;
        try self.createFramebuffers();
        try self.createCommandPool();
        try self.createVertexBuffer();
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
            .apiVersion = c.VK_API_VERSION_1_0,
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

    fn createSwapchain(self: *App) !void {
        const support = try self.querySwapchainSupport(self.physical_device);
        defer support.deinit(self.allocator);

        const surface_format = chooseSwapSurfaceFormat(support.formats);
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
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
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
        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };
        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };
        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };
        try vkCheck(c.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass));
    }

    fn createGraphicsPipeline(self: *App) !PipelineBundle {
        const vert_words = try readSpirvWords(self.allocator, self.io, self.vert_path);
        defer self.allocator.free(vert_words);
        const frag_words = try readSpirvWords(self.allocator, self.io, self.frag_path);
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

        const vertex_input_info = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
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
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
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
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        try vkCheck(c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &pipeline_layout));
        errdefer c.vkDestroyPipelineLayout(self.device, pipeline_layout, null);

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
            .pDepthStencilState = null,
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

    fn createFramebuffers(self: *App) !void {
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len);
        errdefer self.allocator.free(self.framebuffers);

        for (self.swapchain_image_views, 0..) |image_view, i| {
            const attachments = [_]c.VkImageView{image_view};
            const framebuffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
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
        const buffer_size: c.VkDeviceSize = @sizeOf(@TypeOf(vertices));
        try self.createBuffer(
            buffer_size,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &self.vertex_buffer,
            &self.vertex_buffer_memory,
        );

        var mapped: ?*anyopaque = null;
        try vkCheck(c.vkMapMemory(self.device, self.vertex_buffer_memory, 0, buffer_size, 0, &mapped));
        const dst: [*]u8 = @ptrCast(mapped.?);
        const src = std.mem.sliceAsBytes(vertices[0..]);
        @memcpy(dst[0..src.len], src);
        c.vkUnmapMemory(self.device, self.vertex_buffer_memory);
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

    fn recordCommandBuffers(self: *App) !void {
        for (self.command_buffers, 0..) |command_buffer, i| {
            const begin_info = c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = 0,
                .pInheritanceInfo = null,
            };
            try vkCheck(c.vkBeginCommandBuffer(command_buffer, &begin_info));

            const clear_color = c.VkClearValue{ .color = .{ .float32 = .{ 0.025, 0.025, 0.035, 1.0 } } };
            const render_pass_info = c.VkRenderPassBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .pNext = null,
                .renderPass = self.render_pass,
                .framebuffer = self.framebuffers[i],
                .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
                .clearValueCount = 1,
                .pClearValues = &clear_color,
            };
            c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.graphics_pipeline);
            c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
            c.vkCmdEndRenderPass(command_buffer);
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
            try vkCheck(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished[i]));
            try vkCheck(c.vkCreateFence(self.device, &fence_info, null, &self.in_flight[i]));
        }
    }

    fn drawFrame(self: *App) !void {
        try vkCheck(c.vkWaitForFences(self.device, 1, &self.in_flight[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));

        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.image_available[self.current_frame], null, &image_index);
        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            return;
        }
        try vkCheckAllowSuboptimal(acquire_result);

        try vkCheck(c.vkResetFences(self.device, 1, &self.in_flight[self.current_frame]));

        const wait_semaphores = [_]c.VkSemaphore{self.image_available[self.current_frame]};
        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]c.VkSemaphore{self.render_finished[self.current_frame]};
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
        const present_result = c.vkQueuePresentKHR(self.present_queue, &present_info);
        if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.recreateSwapchain();
        } else {
            try vkCheck(present_result);
        }

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
    }

    fn reloadShadersIfChanged(self: *App) !void {
        const new_vert_mtime = fileMtime(self.io, self.vert_path) catch return;
        const new_frag_mtime = fileMtime(self.io, self.frag_path) catch return;
        if (new_vert_mtime == self.vert_mtime and new_frag_mtime == self.frag_mtime) return;

        std.debug.print("detected shader update; reloading...\n", .{});
        try vkCheck(c.vkDeviceWaitIdle(self.device));

        const new_bundle = self.createGraphicsPipeline() catch |err| {
            std.debug.print("shader reload failed: {s}; keeping previous pipeline\n", .{@errorName(err)});
            return;
        };

        c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.graphics_pipeline = new_bundle.pipeline;
        self.pipeline_layout = new_bundle.layout;
        try self.recreateCommandBuffers();
        self.vert_mtime = new_vert_mtime;
        self.frag_mtime = new_frag_mtime;
        std.debug.print("shader reload ok\n", .{});
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
        try self.createImageViews();
        try self.createRenderPass();
        const bundle = try self.createGraphicsPipeline();
        self.pipeline_layout = bundle.layout;
        self.graphics_pipeline = bundle.pipeline;
        try self.createFramebuffers();
        try self.createCommandBuffers();
    }

    fn cleanupSwapchain(self: *App) void {
        if (self.command_buffers.len > 0 and self.command_pool != null) {
            c.vkFreeCommandBuffers(self.device, self.command_pool, @intCast(self.command_buffers.len), self.command_buffers.ptr);
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }
        for (self.framebuffers) |framebuffer| c.vkDestroyFramebuffer(self.device, framebuffer, null);
        self.allocator.free(self.framebuffers);
        self.framebuffers = &.{};

        if (self.graphics_pipeline != null) c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        self.graphics_pipeline = null;
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.pipeline_layout = null;
        if (self.render_pass != null) c.vkDestroyRenderPass(self.device, self.render_pass, null);
        self.render_pass = null;

        for (self.swapchain_image_views) |image_view| c.vkDestroyImageView(self.device, image_view, null);
        self.allocator.free(self.swapchain_image_views);
        self.swapchain_image_views = &.{};
        self.allocator.free(self.swapchain_images);
        self.swapchain_images = &.{};
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
    }
};

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
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const vert_path = args.next() orelse default_vert_path;
    const frag_path = args.next() orelse default_frag_path;

    var app = try App.init(allocator, init.io, vert_path, frag_path);
    defer app.deinit();
    try app.run();
}
