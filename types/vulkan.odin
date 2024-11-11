package types

import "../config"
import "vendor:glfw"
import vk "vendor:vulkan"

s_Window :: struct {
	handle:                        glfw.WindowHandle,
	vk_instance:                   vk.Instance,
	vk_surface:                    vk.SurfaceKHR,
	vk_device:                     vk.Device,
	vk_physical_device:            vk.PhysicalDevice,
	vk_graphics_queue:             vk.Queue,
	vk_present_queue:              vk.Queue,
	vk_framebuffer_resized:        bool,
	vk_swapchain:                  vk.SwapchainKHR,
	vk_swapchain_images:           []vk.Image,
	vk_swapchain_views:            []vk.ImageView,
	vk_swapchain_format:           vk.SurfaceFormatKHR,
	vk_swapchain_extent:           vk.Extent2D,
	vk_swapchain_extend3:          vk.Extent3D,
	vk_swapchain_frame_buffers:    []vk.Framebuffer,
	vk_render_pass:                vk.RenderPass,
	vk_pipeline_layout:            vk.PipelineLayout,
	vk_pipeline:                   vk.Pipeline,
	vk_command_pool:               vk.CommandPool,
	vk_command_buffers:            [config.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	vk_image_available_semaphores: [config.MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	vk_render_finished_semaphores: [config.MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	vk_in_flight_fences:           [config.MAX_FRAMES_IN_FLIGHT]vk.Fence,
}

s_WindowConfig :: struct {
	size:         [2]i32,
	scale:        [2]f32,
	refresh_rate: u16,
}

Queue_Family_Indices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

Swapchain_Support :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}