package init

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "vendor:glfw"

import vk "vendor:vulkan"

import "../config"
import "../shared_"
import "../types"

vk_framebuffer_resized: bool = false

Init :: proc() {
	if !glfw.Init() {
		log.panic("glfw: could not be initialized")
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
}

CreateWindow :: proc(window: ^types.s_Window, config: ^types.s_WindowConfig) {
	window.handle = glfw.CreateWindow(config.size.x, config.size.y, "Vulkan", nil, nil)
}

LoadProcAddr :: proc() {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
}

CheckInstance :: proc() {
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")
}

CreateInfo :: proc(create_info: ^vk.InstanceCreateInfo) {
	create_info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Hello Triangle",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "No Engine",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_0,
		},
	}
}

AddMacOS_Flags :: proc(create_info: ^vk.InstanceCreateInfo, extensions: ^[dynamic]cstring) {
	create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
	append(extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
}

CheckValidationLayers :: proc(
	create_info: ^vk.InstanceCreateInfo,
	extensions: ^[dynamic]cstring,
	vk_message_callback: vk.ProcDebugUtilsMessengerCallbackEXT,
	dbg_create_info: ^vk.DebugUtilsMessengerCreateInfoEXT,
) {
	create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
	create_info.enabledLayerCount = 1

	append(extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

	// Severity based on logger level.
	severity: vk.DebugUtilsMessageSeverityFlagsEXT
	if context.logger.lowest_level <= .Error {
		severity |= {.ERROR}
	}
	if context.logger.lowest_level <= .Warning {
		severity |= {.WARNING}
	}
	if context.logger.lowest_level <= .Info {
		severity |= {.INFO}
	}
	if context.logger.lowest_level <= .Debug {
		severity |= {.VERBOSE}
	}

	dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = severity,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING},
		pfnUserCallback = vk_message_callback,
	}
	create_info.pNext = &dbg_create_info
}

LoadProcAdrrInstance :: proc(window: ^types.s_Window) {
	vk.load_proc_addresses_instance(window.vk_instance)
}
@(require_results)
PickPhysicalDevice :: proc(window: ^types.s_Window) -> vk.Result {

	score_physical_device :: proc(
		device: vk.PhysicalDevice,
		window: ^types.s_Window,
	) -> (
		score: int,
	) {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)

		name := ByteArrStr(&props.deviceName)
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)

		features: vk.PhysicalDeviceFeatures
		vk.GetPhysicalDeviceFeatures(device, &features)

		// // App can't function without geometry shaders.
		if !features.geometryShader {
			log.info("vulkan: device does not support geometry shaders")
			return 0
		}

		// Need certain extensions supported.
		{
			extensions, result := PhysicalDeviceExt(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: enumerate device extension properties failed: %v", result)
				return 0
			}

			required_loop: for required in config.DEVICE_EXTENSIONS {
				for &extension in extensions {
					name := ByteArrStr(&extension.extensionName)
					if name == string(required) {
						continue required_loop
					}
				}

				log.infof("vulkan: device does not support required extension %q", required)
				return 0
			}
		}

		{
			support, result := QuerySwapchainSupport(device, context.temp_allocator, window)
			if result != .SUCCESS {
				log.infof("vulkan: query swapchain support failure: %v", result)
				return 0
			}

			// Need at least a format and present mode.
			if len(support.formats) == 0 || len(support.presentModes) == 0 {
				log.info("vulkan: device does not support swapchain")
				return 0
			}
		}

		families := FindQueueFamilies(device, window)
		if _, has_graphics := families.graphics.?; !has_graphics {
			log.info("vulkan: device does not have a graphics queue")
			return 0
		}
		if _, has_present := families.present.?; !has_present {
			log.info("vulkan: device does not have a presentation queue")
			return 0
		}

		// Favor GPUs.
		switch props.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log.infof("vulkan: scored %i based on device type %v", score, props.deviceType)

		// Maximum texture size.
		score += int(props.limits.maxImageDimension2D)
		score += int(props.limits.maxImageDimension3D)
		log.infof(
			"vulkan: added the max 2D and 3D image dimensions (texture size) of %v to the score",
			props.limits.maxImageDimension2D,
		)
		return
	}

	count: u32
	vk.EnumeratePhysicalDevices(window.vk_instance, &count, nil) or_return
	if count == 0 {log.panic("vulkan: no GPU found")}

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(window.vk_instance, &count, raw_data(devices)) or_return

	best_device_score := -1
	for device in devices {
		if score := score_physical_device(device, window); score > best_device_score {
			window.vk_physical_device = device
			best_device_score = score
		}
	}

	if best_device_score <= 0 {
		log.panic("vulkan: no suitable GPU found")
	}
	return .SUCCESS
}

PhysicalDeviceExt :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	exts: []vk.ExtensionProperties,
	res: vk.Result,
) {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) or_return

	exts = make([]vk.ExtensionProperties, count, allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts)) or_return

	return
}

ByteArrStr :: proc(arr: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(arr[:]), 0)
}

QuerySwapchainSupport :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
	window: ^types.s_Window,
) -> (
	support: types.Swapchain_Support,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		device,
		window.vk_surface,
		&support.capabilities,
	) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, window.vk_surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			device,
			window.vk_surface,
			&count,
			raw_data(support.formats),
		) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			window.vk_surface,
			&count,
			nil,
		) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			window.vk_surface,
			&count,
			raw_data(support.presentModes),
		) or_return
	}

	return
}

CreateSwapchain :: proc(window: ^types.s_Window) {
	indices := FindQueueFamilies(window.vk_physical_device, window)

	// Setup swapchain.
	{
		support, result := QuerySwapchainSupport(
			window.vk_physical_device,
			context.temp_allocator,
			window,
		)
		if result != .SUCCESS {
			log.panicf("vulkan: query swapchain failed: %v", result)
		}

		surface_format := ChooseSwapchainSurfaceFormat(support.formats)
		present_mode := ChooseSwapchainPresentMode(support.presentModes)
		extent := ChooseSwapchainExtent(support.capabilities, window)

		window.vk_swapchain_format = surface_format
		window.vk_swapchain_extent = extent

		image_count := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 &&
		   image_count > support.capabilities.maxImageCount {
			image_count = support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = window.vk_surface,
			minImageCount    = image_count,
			imageFormat      = surface_format.format,
			imageColorSpace  = surface_format.colorSpace,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = present_mode,
			clipped          = true,
		}

		if indices.graphics != indices.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data(
				[]u32{indices.graphics.?, indices.present.?},
			)
		}

		shared_.must(
			vk.CreateSwapchainKHR(window.vk_device, &create_info, nil, &window.vk_swapchain),
		)
	}

	// Setup swapchain images.
	{
		count: u32
		shared_.must(vk.GetSwapchainImagesKHR(window.vk_device, window.vk_swapchain, &count, nil))

		window.vk_swapchain_images = make([]vk.Image, count)
		window.vk_swapchain_views = make([]vk.ImageView, count)
		shared_.must(
			vk.GetSwapchainImagesKHR(
				window.vk_device,
				window.vk_swapchain,
				&count,
				raw_data(window.vk_swapchain_images),
			),
		)

		for image, i in window.vk_swapchain_images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = window.vk_swapchain_format.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			shared_.must(
				vk.CreateImageView(
					window.vk_device,
					&create_info,
					nil,
					&window.vk_swapchain_views[i],
				),
			)
		}
	}
}

RecreateSwapchain :: proc(window: ^types.s_Window) {
	// Don't do anything when minimized.
	for w, h := glfw.GetFramebufferSize(window.handle);
	    w == 0 || h == 0;
	    w, h = glfw.GetFramebufferSize(window.handle) {
		glfw.WaitEvents()

		// Handle closing while minimized.
		if glfw.WindowShouldClose(window.handle) {break}
	}

	vk.DeviceWaitIdle(window.vk_device)

	DestroyFrameBuffers(window)
	DestroySwapchain(window)

	CreateSwapchain(window)
	CreateFrameBuffers(window)
}

DestroyFrameBuffers :: proc(window: ^types.s_Window) {
	for frame_buffer in window.vk_swapchain_frame_buffers {vk.DestroyFramebuffer(window.vk_device, frame_buffer, nil)}
	delete(window.vk_swapchain_frame_buffers)
}

CreateFrameBuffers :: proc(window: ^types.s_Window) {
	window.vk_swapchain_frame_buffers = make([]vk.Framebuffer, len(window.vk_swapchain_views))
	for view, i in window.vk_swapchain_views {
		attachments := []vk.ImageView{view}

		frame_buffer := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = window.vk_render_pass,
			attachmentCount = 1,
			pAttachments    = raw_data(attachments),
			width           = window.vk_swapchain_extent.width,
			height          = window.vk_swapchain_extent.height,
			layers          = 1,
		}
		shared_.must(
			vk.CreateFramebuffer(
				window.vk_device,
				&frame_buffer,
				nil,
				&window.vk_swapchain_frame_buffers[i],
			),
		)
	}
}

DestroySwapchain :: proc(window: ^types.s_Window) {
	for view in window.vk_swapchain_views {
		vk.DestroyImageView(window.vk_device, view, nil)
	}
	delete(window.vk_swapchain_views)
	delete(window.vk_swapchain_images)
	vk.DestroySwapchainKHR(window.vk_device, window.vk_swapchain, nil)
}


RecordCommandBuffer :: proc(
	command_buffer: vk.CommandBuffer,
	image_index: u32,
	window: ^types.s_Window,
) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	shared_.must(vk.BeginCommandBuffer(command_buffer, &begin_info))

	clear_color := vk.ClearValue{}
	clear_color.color.float32 = {0.0, 0.0, 0.0, 1.0}

	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = window.vk_render_pass,
		framebuffer = window.vk_swapchain_frame_buffers[image_index],
		renderArea = {extent = window.vk_swapchain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)

	vk.CmdBindPipeline(command_buffer, .GRAPHICS, window.vk_pipeline)

	viewport := vk.Viewport {
		width    = f32(window.vk_swapchain_extent.width),
		height   = f32(window.vk_swapchain_extent.height),
		maxDepth = 1000.0,
        minDepth = 0.1,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
        offset = {0, 0},
		extent = window.vk_swapchain_extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	vk.CmdDraw(command_buffer, 3, 1, 0, 0)

	vk.CmdEndRenderPass(command_buffer)

	shared_.must(vk.EndCommandBuffer(command_buffer))
}

FindQueueFamilies :: proc(
	device: vk.PhysicalDevice,
	window: ^types.s_Window,
) -> (
	ids: types.Queue_Family_Indices,
) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), window.vk_surface, &supported)
		if supported {
			ids.present = u32(i)
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_graphics && has_present {
			break
		}
	}

	return
}

ChooseSwapchainSurfaceFormat :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	// Fallback non optimal.
	return formats[0]
}
ChooseSwapchainPresentMode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// We would like mailbox for the best tradeoff between tearing and latency.
	for mode in modes {
		if mode == .MAILBOX {
			return .MAILBOX
		}
	}

	// As a fallback, fifo (basically vsync) is always available.
	return .FIFO
}

ChooseSwapchainExtent :: proc(
	capabilities: vk.SurfaceCapabilitiesKHR,
	window: ^types.s_Window,
) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(window.handle)
	return (vk.Extent2D {
				width = clamp(
					u32(width),
					capabilities.minImageExtent.width,
					capabilities.maxImageExtent.width,
				),
				height = clamp(
					u32(height),
					capabilities.minImageExtent.height,
					capabilities.maxImageExtent.height,
				),
			})
}

SetIndices :: proc(
	indices: types.Queue_Family_Indices,
	create_info: ^vk.InstanceCreateInfo,
	window: ^types.s_Window,
) {
	indices_set := make(map[u32]struct {}, allocator = context.temp_allocator)
	indices_set[indices.graphics.?] = {}
	indices_set[indices.present.?] = {}

	queue_create_infos := make(
		[dynamic]vk.DeviceQueueCreateInfo,
		0,
		len(indices_set),
		context.temp_allocator,
	)
	for family in indices_set {
		append(
			&queue_create_infos,
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = indices.graphics.?,
				queueCount = 1,
				pQueuePriorities = raw_data([]f32{1}),
			}, // Scheduling priority between 0 and 1.
		)
	}

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pQueueCreateInfos       = raw_data(queue_create_infos),
		queueCreateInfoCount    = u32(len(queue_create_infos)),
		enabledLayerCount       = create_info.enabledLayerCount,
		ppEnabledLayerNames     = create_info.ppEnabledLayerNames,
		ppEnabledExtensionNames = raw_data(config.DEVICE_EXTENSIONS),
		enabledExtensionCount   = u32(len(config.DEVICE_EXTENSIONS)),
	}

	shared_.must(
		vk.CreateDevice(window.vk_physical_device, &device_create_info, nil, &window.vk_device),
	)

	vk.GetDeviceQueue(window.vk_device, indices.graphics.?, 0, &window.vk_graphics_queue)
	vk.GetDeviceQueue(window.vk_device, indices.present.?, 0, &window.vk_present_queue)
}

RenderPass :: proc(window: ^types.s_Window) {
	color_attachment := vk.AttachmentDescription {
		format         = window.vk_swapchain_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}

	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}

	render_pass := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	shared_.must(vk.CreateRenderPass(window.vk_device, &render_pass, nil, &window.vk_render_pass))
}

SetUpShaders :: proc(
	vert_code, frag_code: []u8,
	vert_shader_module, frag_shader_module: ^vk.ShaderModule,
	shader_stages: ^[2]vk.PipelineShaderStageCreateInfo,
	window: ^types.s_Window,
) {
	vert_shader_module := CreateShaderModule(vert_code, window)
	shader_stages[0] = vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.VERTEX},
		module = vert_shader_module,
		pName  = "main",
	}

	frag_shader_module := CreateShaderModule(frag_code, window)
	shader_stages[1] = vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.FRAGMENT},
		module = frag_shader_module,
		pName  = "main",
	}
}

CreateShaderModule :: proc(code: []byte, window: ^types.s_Window) -> (module: vk.ShaderModule) {
	as_u32 := slice.reinterpret([]u32, code)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(as_u32),
	}
	shared_.must(vk.CreateShaderModule(window.vk_device, &create_info, nil, &module))
	return
}

SetUpPipeline :: proc(
	window: ^types.s_Window,
	shader_stages: ^[2]vk.PipelineShaderStageCreateInfo,
) {
	{
		dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
		dynamic_state := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates    = raw_data(dynamic_states),
		}

		vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		}

		input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
			sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		viewport_state := vk.PipelineViewportStateCreateInfo {
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount  = 1,
		}

		rasterizer := vk.PipelineRasterizationStateCreateInfo {
			sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			lineWidth   = 1,
			cullMode    = {.BACK},
			frontFace   = .CLOCKWISE,
		}

		multisampling := vk.PipelineMultisampleStateCreateInfo {
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
			minSampleShading     = 1,
		}

		color_blend_attachment := vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
		}

		color_blending := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_blend_attachment,
		}

		pipeline_layout := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
		}
		shared_.must(
			vk.CreatePipelineLayout(
				window.vk_device,
				&pipeline_layout,
				nil,
				&window.vk_pipeline_layout,
			),
		)

		pipeline := vk.GraphicsPipelineCreateInfo {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount          = 2,
			pStages             = &shader_stages[0],
			pVertexInputState   = &vertex_input_info,
			pInputAssemblyState = &input_assembly,
			pViewportState      = &viewport_state,
			pRasterizationState = &rasterizer,
			pMultisampleState   = &multisampling,
			pColorBlendState    = &color_blending,
			pDynamicState       = &dynamic_state,
			layout              = window.vk_pipeline_layout,
			renderPass          = window.vk_render_pass,
			subpass             = 0,
			basePipelineIndex   = -1,
		}
		shared_.must(
			vk.CreateGraphicsPipelines(
				window.vk_device,
				0,
				1,
				&pipeline,
				nil,
				&window.vk_pipeline,
			),
		)
	}
}

CreateCommandPool :: proc(indices: ^types.Queue_Family_Indices, window: ^types.s_Window) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = indices.graphics.?,
	}
	shared_.must(vk.CreateCommandPool(window.vk_device, &pool_info, nil, &window.vk_command_pool))

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = window.vk_command_pool,
		level              = .PRIMARY,
		commandBufferCount = config.MAX_FRAMES_IN_FLIGHT,
	}
	shared_.must(
		vk.AllocateCommandBuffers(window.vk_device, &alloc_info, &window.vk_command_buffers[0]),
	)
}

SetUpSyncPrimitives :: proc(
    window: ^types.s_Window
) {
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< config.MAX_FRAMES_IN_FLIGHT {
		shared_.must(
			vk.CreateSemaphore(
				window.vk_device,
				&sem_info,
				nil,
				&window.vk_image_available_semaphores[i],
			),
		)
		shared_.must(
			vk.CreateSemaphore(
				window.vk_device,
				&sem_info,
				nil,
				&window.vk_render_finished_semaphores[i],
			),
		)
		shared_.must(
			vk.CreateFence(window.vk_device, &fence_info, nil, &window.vk_in_flight_fences[i]),
		)
	}
}

FullInit :: proc(
    window: ^types.s_Window,
    window_config: ^types.s_WindowConfig,
    create_info: ^vk.InstanceCreateInfo,
    glfw_error_callback: glfw.ErrorProc,
    extensions: ^[dynamic]cstring,
    vert_shader_code, frag_shader_code: []u8,
    vert_shader_mod, frag_shader_mod: ^vk.ShaderModule,
    shader_stages: ^[2]vk.PipelineShaderStageCreateInfo,
) -> (err: vk.Result) {
    glfw.SetErrorCallback(glfw_error_callback)
    Init()
    CreateWindow(window, window_config)
    
    glfw.SetFramebufferSizeCallback(window.handle, proc "c" (_: glfw.WindowHandle, _, _: i32) {
        vk_framebuffer_resized = true
    })
    window.vk_framebuffer_resized = vk_framebuffer_resized || false

    LoadProcAddr()
    CheckInstance()
    CreateInfo(create_info)
    extensions := slice.clone_to_dynamic(
        glfw.GetRequiredInstanceExtensions(),
        context.temp_allocator,
    )

    when ODIN_OS == .Darwin {
        AddMacOS_Flags(&create_info, &extensions)
    }
    
    dbgCreateInfo: vk.DebugUtilsMessengerCreateInfoEXT
    create_info.enabledExtensionCount = u32(len(extensions))
    create_info.ppEnabledExtensionNames = raw_data(extensions)

    if err = vk.CreateInstance(create_info, nil, &window.vk_instance); err != .SUCCESS {
        return err
    }

    LoadProcAdrrInstance(window)

    if err = glfw.CreateWindowSurface(window.vk_instance, window.handle, nil, &window.vk_surface); err != .SUCCESS {
        return err
    }

    if err = PickPhysicalDevice(window); err != .SUCCESS {
        return err
    }

    indices := FindQueueFamilies(window.vk_physical_device, window)
    SetIndices(indices, create_info, window)

    CreateSwapchain(window)
    
    SetUpShaders(
        vert_shader_code,
        frag_shader_code,
        vert_shader_mod,
        frag_shader_mod,
        shader_stages,
        window
    )

    RenderPass(window)
    CreateFrameBuffers(window)
    SetUpPipeline(window, shader_stages)

    // Create command pool and sync primitives
    CreateCommandPool(&indices, window)
    SetUpSyncPrimitives(window)
    
    return .SUCCESS
}

Cleanup :: proc(
    window: ^types.s_Window,
    vert_shader_mod, frag_shader_mod: vk.ShaderModule
) {
    vk.DeviceWaitIdle(window.vk_device)
    
    // Clean up sync objects
    for sem in window.vk_image_available_semaphores {
        vk.DestroySemaphore(window.vk_device, sem, nil)
    }
    for sem in window.vk_render_finished_semaphores {
        vk.DestroySemaphore(window.vk_device, sem, nil)
    }
    for fence in window.vk_in_flight_fences {
        vk.DestroyFence(window.vk_device, fence, nil)
    }
    
    vk.DestroyCommandPool(window.vk_device, window.vk_command_pool, nil)
    vk.DestroyPipeline(window.vk_device, window.vk_pipeline, nil)
    vk.DestroyPipelineLayout(window.vk_device, window.vk_pipeline_layout, nil)
    DestroyFrameBuffers(window)
    vk.DestroyRenderPass(window.vk_device, window.vk_render_pass, nil)
    vk.DestroyShaderModule(window.vk_device, vert_shader_mod, nil)
    vk.DestroyShaderModule(window.vk_device, frag_shader_mod, nil)
    DestroySwapchain(window)
    vk.DestroyDevice(window.vk_device, nil)
    vk.DestroySurfaceKHR(window.vk_instance, window.vk_surface, nil)
    vk.DestroyInstance(window.vk_instance, nil)
    glfw.DestroyWindow(window.handle)
    glfw.Terminate()
}

ValidateVulkanResources :: proc(window: ^types.s_Window) -> bool {
    if window == nil {
        log.error("Window struct is nil")
        return false
    }
    
    if window.vk_device == nil {
        log.error("Vulkan logical device handle is invalid")
        return false
    }
    
    if window.vk_swapchain == 0 {
        log.error("Vulkan swapchain handle is invalid")
        return false
    }
    
    if window.vk_graphics_queue == nil {
        log.error("Graphics queue handle is invalid")
        return false
    }
    
    if window.vk_present_queue == nil {
        log.error("Present queue handle is invalid")
        return false
    }
    
    // Validate command buffers
    for command_buffer, i in window.vk_command_buffers {
        if command_buffer == nil {
            log.errorf("Command buffer %d is invalid", i)
            return false
        }
    }
    
    // Validate synchronization primitives
    for i in 0..<config.MAX_FRAMES_IN_FLIGHT {
        if window.vk_image_available_semaphores[i] == 0 {
            log.errorf("Image available semaphore %d is invalid", i)
            return false
        }
        if window.vk_render_finished_semaphores[i] == 0 {
            log.errorf("Render finished semaphore %d is invalid", i)
            return false
        }
        if window.vk_in_flight_fences[i] == 0 {
            log.errorf("In-flight fence %d is invalid", i)
            return false
        }
    }
    
    return true
}