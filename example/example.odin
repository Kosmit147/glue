package example

import glue ".."

import "core:log"

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)
	defer log.destroy_console_logger(context.logger)

	if !glue.create_window(1920, 1080, "Example") do log.panic("Failed to create a window")
	defer glue.destroy_window()

	for !glue.window_should_close() {
		glue.poll_events()
		glue.swap_buffers()
		free_all(context.temp_allocator)
	}
}
