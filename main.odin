package main

/* MARK: Imports */

// NOTE: Core imports
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// NOTE: Vendor imports
import "vendor:glfw"
import vk "vendor:vulkan"

// NOTE: Custom packages imports
import "cbind"
import "config"
import "init"
import "shared_"
import "types"

/* NOTE: Imports end */

/* MARK: MacOS imports */
when ODIN_OS == .Darwin {
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}
/* NOTE: Macos end */

SHADER_VERT :: #load("shaders/vert.spv")
SHADER_FRAG :: #load("shaders/frag.spv")

g_ctx: runtime.Context
WINDOW: types.s_Window
WINDOW_CONFIG: types.s_WindowConfig = {{800, 600}, {1, 1}, 144}

CREATE_INFO: vk.InstanceCreateInfo
EXTENSIONS: [dynamic]cstring

VERT_SHADER_MOD: vk.ShaderModule
FRAG_SHADER_MOD: vk.ShaderModule
SHADER_STAGES: [2]vk.PipelineShaderStageCreateInfo

main :: proc() {
	context.logger = log.create_console_logger(log.Level.Info)
	g_ctx = context

	if err := init.FullInit(
		&WINDOW,
		&WINDOW_CONFIG,
		&CREATE_INFO,
		GLFW_ErrorCallback,
		&EXTENSIONS,
		SHADER_VERT,
		SHADER_FRAG,
		&VERT_SHADER_MOD,
		&FRAG_SHADER_MOD,
		&SHADER_STAGES,
	); err != .SUCCESS {
		log.panic("Failed to Init", err)
	}
	defer init.Cleanup(&WINDOW, VERT_SHADER_MOD, FRAG_SHADER_MOD)

	if !init.ValidateVulkanResources(&WINDOW) {
		log.panic("Vulkan resources are invalid")
	}

	// ...
	currentFrame := 0
	lastFrame := 0
	startTime: f32 = 0
	currTime: f32 = 0
	prevTime: f32 = f32(glfw.GetTime())
	fps: f16 = 0.0
	lastFps: f16 = 0.0
	fpsFiltered: u32 = 0
	deltaTime: f16 = 0.0
	fpsFilterBias: f32 = 0.1
	MAX_FPS_CAP: f16 = 240.0
	targetFrameTime: f16 = 1.0 / MAX_FPS_CAP

	log.info("Target frame time: ", targetFrameTime)
	log.info("Max fps: ", MAX_FPS_CAP)

	glfw.SetWindowUserPointer(WINDOW.handle, &WINDOW)

	for !glfw.WindowShouldClose(WINDOW.handle) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		currTime = f32(glfw.GetTime())
		deltaTime = f16(currTime - prevTime)

		if deltaTime < f16(targetFrameTime) {

			time.sleep(time.Duration(GetFrameSleepTime(deltaTime, targetFrameTime)))

			// Update times after sleeping
			currTime = f32(glfw.GetTime())
			deltaTime = f16(currTime - prevTime)
		}
		prevTime = currTime

		lastFps = fps
		fps = (1.0 / deltaTime)

		WaitForPrevFrame(currentFrame)

		fpsFiltered = u32(
			f32(fpsFiltered) * (1.0 - fpsFilterBias) + f32((lastFps + fps) / 2) * fpsFilterBias,
		)

        UpdateWindowTitle(deltaTime, fpsFiltered)

		imageIdx: u32
		if fail := AquireResult(currentFrame, &imageIdx); fail {
			log.warn("AquireResult is erroring!")
			break
		}

		ResetFences(currentFrame)
		ResetCommBuff(currentFrame)
		RecordCommBuff(currentFrame, &imageIdx, &WINDOW)
		SubmitInfo(currentFrame, &WINDOW)
		PresentInfo(currentFrame, &imageIdx, &WINDOW)

        if ok := Loop(currentFrame, deltaTime, &WINDOW); !ok {
			log.panic("Main loop failed")
        }

		currentFrame = (currentFrame + 1) % config.MAX_FRAMES_IN_FLIGHT
	}
	// ...
	vk.DeviceWaitIdle(WINDOW.vk_device)
}

Loop :: proc(current_frame: int, delta_time: f16, window: ^types.s_Window) -> (ok: bool) {
    return true
}

GetFrameSleepTime :: proc(delta_time: f16, target_frame_time: f16) -> (sleeptime: u32) {
    return u32(f32(target_frame_time - delta_time) * 999999999.9 + 0.1)
}

UpdateWindowTitle :: proc(delta_time: f16, fps_filtered: u32) {
	newTitle := strings.unsafe_string_to_cstring(
		fmt.tprintf("|>  MyGame  |  FPS: %7d |  Frame Time: %.4fms  <|", fps_filtered, delta_time),
	)
	glfw.SetWindowTitle(WINDOW.handle, newTitle)
}
WaitForPrevFrame :: proc(current_frame: int) {
	shared_.must(
		vk.WaitForFences(
			WINDOW.vk_device,
			1,
			&WINDOW.vk_in_flight_fences[current_frame],
			true,
			max(u64),
		),
	)
}
AquireResult :: proc(current_frame: int, image_idx: ^u32) -> (fail: bool) {
	if image_idx == nil {
		log.error("Image index pointer is nil")
		return true
	}

	if current_frame >= config.MAX_FRAMES_IN_FLIGHT {
		log.errorf("Invalid current_frame index: %d", current_frame)
		return true
	}

	acquireResult := vk.AcquireNextImageKHR(
		WINDOW.vk_device,
		WINDOW.vk_swapchain,
		max(u64),
		WINDOW.vk_image_available_semaphores[current_frame],
		0,
		image_idx,
	)

	#partial switch acquireResult {
	case .ERROR_OUT_OF_DATE_KHR:
		log.info("Swapchain out of date, recreating...")
		init.RecreateSwapchain(&WINDOW)
		return true
	case .SUCCESS:
		return false
	case .SUBOPTIMAL_KHR:
		log.warn("Swapchain is suboptimal")
		return false
	case:
		log.errorf("Failed to acquire next image: %v", acquireResult)
		return true
	}
}
ResetFences :: proc(current_frame: int) {
	shared_.must(vk.ResetFences(WINDOW.vk_device, 1, &WINDOW.vk_in_flight_fences[current_frame]))
}
ResetCommBuff :: proc(current_frame: int) {
	shared_.must(vk.ResetCommandBuffer(WINDOW.vk_command_buffers[current_frame], {}))
}
RecordCommBuff :: proc(current_frame: int, image_idx: ^u32, window: ^types.s_Window) {
	init.RecordCommandBuffer(window.vk_command_buffers[current_frame], image_idx^, window)

}
SubmitInfo :: proc(current_frame: int, window: ^types.s_Window) {
	submitInfo := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &WINDOW.vk_image_available_semaphores[current_frame],
		pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
		commandBufferCount   = 1,
		pCommandBuffers      = &WINDOW.vk_command_buffers[current_frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &WINDOW.vk_render_finished_semaphores[current_frame],
	}
	shared_.must(
		vk.QueueSubmit(
			window.vk_graphics_queue,
			1,
			&submitInfo,
			window.vk_in_flight_fences[current_frame],
		),
	)
}
PresentInfo :: proc(current_frame: int, image_idx: ^u32, window: ^types.s_Window) {
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &window.vk_render_finished_semaphores[current_frame],
		swapchainCount     = 1,
		pSwapchains        = &window.vk_swapchain,
		pImageIndices      = image_idx,
	}
	present_result := vk.QueuePresentKHR(WINDOW.vk_present_queue, &present_info)
	switch {
	case present_result == .ERROR_OUT_OF_DATE_KHR ||
        present_result == .SUBOPTIMAL_KHR ||
        WINDOW.vk_framebuffer_resized:
		WINDOW.vk_framebuffer_resized = false
		init.RecreateSwapchain(window)
	case present_result == .SUCCESS:
	case:
		log.panicf("vulkan: present failure: %v", present_result)
	}
}

GLFW_ErrorCallback :: proc "c" (code: i32, description: cstring) {
	context = g_ctx
	log.errorf("glfw: %i: %s", code, description)
}

VkMessengerCallback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}
