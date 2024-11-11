package config

import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 4
DEVICE_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}