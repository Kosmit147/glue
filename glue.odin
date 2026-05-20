package glue

import "base:runtime"

import "vendor:glfw"
import gl "vendor:OpenGL"
import "vendor/imgui"
import "vendor/imgui/imgui_impl_glfw"
import "vendor/imgui/imgui_impl_opengl3"
import tinyobj "vendor/tinyobjloader"

import "core:bytes"
import "core:c"
import "core:container/queue"
import "core:log"
import "core:path/filepath"
import "core:os"
import "core:strings"
import "core:slice"
import "core:image"
import "core:image/png"
import "core:image/jpeg"
import "core:math"
import "core:math/linalg"
import core_time "core:time"

_ :: png
_ :: jpeg

GL_VERSION_MAJOR :: 4
GL_VERSION_MINOR :: 6
IMGUI_FONT_SCALE :: 1.5

_context: runtime.Context

Window :: struct {
	handle: glfw.WindowHandle,
	cursor_enabled: bool,
	raw_mouse_motion_enabled: bool,
	fps_limit: Maybe(u32),
	target_frame_time: f64,
	prev_swap_buffers_time: f64,
}

_window: Window
_event_queue: queue.Queue(Event)

Event :: union #no_nil {
	Key_Pressed_Event,
	Key_Released_Event,
	Mouse_Button_Pressed_Event,
	Mouse_Button_Released_Event,
}

init :: proc(width, height: i32,
			 title: cstring,
			 maximized := false,
			 vsync := true,
			 fps_limit: Maybe(u32) = nil,
			 gl_debug_context := ODIN_DEBUG) -> (ok := false) {
	_context = context

	queue.init(&_event_queue)
	defer if !ok do queue.destroy(&_event_queue)

	glfw.SetErrorCallback(_glfw_error_callback)

	if !glfw.Init() do return
	defer if !ok do glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_VERSION_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_VERSION_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, c.int(gl_debug_context))
	glfw.WindowHint(glfw.MAXIMIZED, glfw.TRUE if maximized else glfw.FALSE)

	_window.handle = glfw.CreateWindow(width, height, title, nil, nil)
	if _window.handle == nil do return
	defer if !ok do glfw.DestroyWindow(_window.handle)

	glfw.MakeContextCurrent(_window.handle)
	glfw.SwapInterval(1 if vsync else 0)

	if limit, limit_set := fps_limit.?; limit_set do enable_fps_limit(limit)
	else do disable_fps_limit()

	glfw.SetFramebufferSizeCallback(_window.handle, _glfw_framebuffer_size_callback)
	glfw.SetKeyCallback(_window.handle, _glfw_key_callback)
	glfw.SetMouseButtonCallback(_window.handle, _glfw_mouse_button_callback)
	glfw.SetCursorPosCallback(_window.handle, _glfw_cursor_position_callback)

	gl.load_up_to(GL_VERSION_MAJOR, GL_VERSION_MINOR, glfw.gl_set_proc_address)

	if gl_debug_context {
		gl.Enable(gl.DEBUG_OUTPUT)
		gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
	}

	log.infof("Initialized OpenGL Context")
	log.infof("Vendor: %v", gl.GetString(gl.VENDOR))
	log.infof("Renderer: %v", gl.GetString(gl.RENDERER))
	log.infof("Version: %v", gl.GetString(gl.VERSION))

	gl.Viewport(0, 0, glfw.GetFramebufferSize(_window.handle))

	_init_input()

	_init_imgui()
	defer if !ok do _deinit_imgui()

	ok = true
	return
}

deinit :: proc() {
	_deinit_imgui()
	glfw.DestroyWindow(_window.handle)
	glfw.Terminate()
	_window.handle = nil
	queue.destroy(&_event_queue)
}

window_handle :: proc() -> glfw.WindowHandle {
	return _window.handle
}

window_should_close :: proc() -> bool {
	return cast(bool)glfw.WindowShouldClose(_window.handle)
}

close_window :: proc() {
	glfw.SetWindowShouldClose(_window.handle, glfw.TRUE)
}

begin_frame :: proc() {
	_input_new_frame()
	glfw.PollEvents()
	_imgui_new_frame()
}

end_frame :: proc() {
	_imgui_render()
	_swap_buffers()
}

_swap_buffers :: proc() {
	glfw.SwapBuffers(_window.handle)
	current_frame_time := time() - _window.prev_swap_buffers_time
	if current_frame_time < _window.target_frame_time {
		sleep_time := _window.target_frame_time - current_frame_time
		core_time.accurate_sleep(core_time.Duration(sleep_time * f64(core_time.Second)))
	}
	_window.prev_swap_buffers_time = time()
}

pop_event :: proc() -> (Event, bool) {
	return queue.pop_front_safe(&_event_queue)
}

_push_event :: proc(event: Event) {
	queue.push_back(&_event_queue, event)
}

MIN_FPS_LIMIT :: 1

enable_fps_limit :: proc(limit: u32) {
	limit := max(limit, MIN_FPS_LIMIT)
	_window.fps_limit = limit
	_window.target_frame_time = 1.0 / f64(limit)
}

disable_fps_limit :: proc() {
	_window.fps_limit = nil
	_window.target_frame_time = 0
}

@(require_results)
fps_limit :: proc() -> (u32, bool) {
	return _window.fps_limit.?
}

@(require_results)
target_frame_time :: proc() -> f64 {
	return _window.target_frame_time
}

@(require_results)
window_size :: proc() -> [2]i32 {
	x, y := glfw.GetWindowSize(_window.handle)
	return { x, y }
}

@(require_results)
framebuffer_size :: proc() -> [2]i32 {
	x, y := glfw.GetFramebufferSize(_window.handle)
	return { x, y }
}

@(require_results)
window_aspect_ratio :: proc() -> f32 {
	window_size := cast(Vec2)window_size()
	return window_size.x / window_size.y
}

@(require_results)
time :: proc() -> f64 {
	return glfw.GetTime()
}

@(require_results)
cursor_enabled :: proc() -> bool {
	return _window.cursor_enabled
}

set_cursor_enabled :: proc(enabled: bool) {
	glfw.SetInputMode(_window.handle, glfw.CURSOR, glfw.CURSOR_NORMAL if enabled else glfw.CURSOR_DISABLED)
	_window.cursor_enabled = enabled
	_input_update_cursor_pos()
}

@(require_results)
raw_mouse_motion_enabled :: proc() -> bool {
	return _window.raw_mouse_motion_enabled
}

set_raw_mouse_motion_enabled :: proc(enabled: bool) {
	if !glfw.RawMouseMotionSupported() do return
	glfw.SetInputMode(_window.handle, glfw.RAW_MOUSE_MOTION, glfw.TRUE if enabled else glfw.FALSE)
	_window.raw_mouse_motion_enabled = enabled
}

@(require_results)
full_screen_enabled :: proc() -> bool {
	return glfw.GetWindowMonitor(_window.handle) != nil
}

set_full_screen_enabled :: proc(full_screen: bool) {
	if full_screen_enabled() == full_screen do return
	monitor := glfw.GetPrimaryMonitor()
	video_mode := glfw.GetVideoMode(monitor)
	glfw.SetWindowMonitor(window = _window.handle,
						  monitor = monitor if full_screen else nil,
						  xpos = 0,
						  ypos = 0,
						  width = video_mode.width,
						  height = video_mode.height,
						  refresh_rate = video_mode.refresh_rate)
}

@(private)
_glfw_error_callback :: proc "c" (error: i32, description: cstring) {
	context = _context
	log.errorf("GLFW Error %v: %v", error, description)
}

@(private)
_glfw_framebuffer_size_callback :: proc "c" (window_handle: glfw.WindowHandle, width, height: i32) {
	gl.Viewport(0, 0, width, height)
}

Key :: enum u8 {
	Unknown,

	Space,
	Apostrophe,
	Comma,
	Minus,
	Period,
	Slash,
	Semicolon,
	Equal,
	Left_Bracket,
	Backslash,
	Right_Bracket,
	Grave_Accent,
	World_1,
	World_2,

	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,

	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,

	Escape,
	Enter,
	Tab,
	Backspace,
	Insert,
	Delete,
	Right,
	Left,
	Down,
	Up,
	Page_Up,
	Page_Down,
	Home,
	End,
	Caps_Lock,
	Scroll_Lock,
	Num_Lock,
	Print_Screen,
	Pause,

	F_1,
	F_2,
	F_3,
	F_4,
	F_5,
	F_6,
	F_7,
	F_8,
	F_9,
	F_10,
	F_11,
	F_12,
	F_13,
	F_14,
	F_15,
	F_16,
	F_17,
	F_18,
	F_19,
	F_20,
	F_21,
	F_22,
	F_23,
	F_24,
	F_25,

	KP_0,
	KP_1,
	KP_2,
	KP_3,
	KP_4,
	KP_5,
	KP_6,
	KP_7,
	KP_8,
	KP_9,

	KP_Decimal,
	KP_Divide,
	KP_Multiply,
	KP_Subtract,
	KP_Add,
	KP_Enter,
	KP_Equal,

	Left_Shift,
	Left_Control,
	Left_Alt,
	Left_Super,
	Right_Shift,
	Right_Control,
	Right_Alt,
	Right_Super,
	Menu,
}

_map_glfw_key :: proc "contextless" (glfw_key: i32) -> Key {
	switch glfw_key {
	case glfw.KEY_SPACE:          return .Space
	case glfw.KEY_APOSTROPHE:     return .Apostrophe
	case glfw.KEY_COMMA:          return .Comma
	case glfw.KEY_MINUS:          return .Minus
	case glfw.KEY_PERIOD:         return .Period
	case glfw.KEY_SLASH:          return .Slash
	case glfw.KEY_SEMICOLON:      return .Semicolon
	case glfw.KEY_EQUAL:          return .Equal
	case glfw.KEY_LEFT_BRACKET:   return .Left_Bracket
	case glfw.KEY_BACKSLASH:      return .Backslash
	case glfw.KEY_RIGHT_BRACKET:  return .Right_Bracket
	case glfw.KEY_GRAVE_ACCENT:   return .Grave_Accent
	case glfw.KEY_WORLD_1:        return .World_1
	case glfw.KEY_WORLD_2:        return .World_2

	case glfw.KEY_0:              return .Num_0
	case glfw.KEY_1:              return .Num_1
	case glfw.KEY_2:              return .Num_2
	case glfw.KEY_3:              return .Num_3
	case glfw.KEY_4:              return .Num_4
	case glfw.KEY_5:              return .Num_5
	case glfw.KEY_6:              return .Num_6
	case glfw.KEY_7:              return .Num_7
	case glfw.KEY_8:              return .Num_8
	case glfw.KEY_9:              return .Num_9

	case glfw.KEY_A:              return .A
	case glfw.KEY_B:              return .B
	case glfw.KEY_C:              return .C
	case glfw.KEY_D:              return .D
	case glfw.KEY_E:              return .E
	case glfw.KEY_F:              return .F
	case glfw.KEY_G:              return .G
	case glfw.KEY_H:              return .H
	case glfw.KEY_I:              return .I
	case glfw.KEY_J:              return .J
	case glfw.KEY_K:              return .K
	case glfw.KEY_L:              return .L
	case glfw.KEY_M:              return .M
	case glfw.KEY_N:              return .N
	case glfw.KEY_O:              return .O
	case glfw.KEY_P:              return .P
	case glfw.KEY_Q:              return .Q
	case glfw.KEY_R:              return .R
	case glfw.KEY_S:              return .S
	case glfw.KEY_T:              return .T
	case glfw.KEY_U:              return .U
	case glfw.KEY_V:              return .V
	case glfw.KEY_W:              return .W
	case glfw.KEY_X:              return .X
	case glfw.KEY_Y:              return .Y
	case glfw.KEY_Z:              return .Z

	case glfw.KEY_ESCAPE:         return .Escape
	case glfw.KEY_ENTER:          return .Enter
	case glfw.KEY_TAB:            return .Tab
	case glfw.KEY_BACKSPACE:      return .Backspace
	case glfw.KEY_INSERT:         return .Insert
	case glfw.KEY_DELETE:         return .Delete
	case glfw.KEY_RIGHT:          return .Right
	case glfw.KEY_LEFT:           return .Left
	case glfw.KEY_DOWN:           return .Down
	case glfw.KEY_UP:             return .Up
	case glfw.KEY_PAGE_UP:        return .Page_Up
	case glfw.KEY_PAGE_DOWN:      return .Page_Down
	case glfw.KEY_HOME:           return .Home
	case glfw.KEY_END:            return .End
	case glfw.KEY_CAPS_LOCK:      return .Caps_Lock
	case glfw.KEY_SCROLL_LOCK:    return .Scroll_Lock
	case glfw.KEY_NUM_LOCK:       return .Num_Lock
	case glfw.KEY_PRINT_SCREEN:   return .Print_Screen
	case glfw.KEY_PAUSE:          return .Pause

	case glfw.KEY_F1:             return .F_1
	case glfw.KEY_F2:             return .F_2
	case glfw.KEY_F3:             return .F_3
	case glfw.KEY_F4:             return .F_4
	case glfw.KEY_F5:             return .F_5
	case glfw.KEY_F6:             return .F_6
	case glfw.KEY_F7:             return .F_7
	case glfw.KEY_F8:             return .F_8
	case glfw.KEY_F9:             return .F_9
	case glfw.KEY_F10:            return .F_10
	case glfw.KEY_F11:            return .F_11
	case glfw.KEY_F12:            return .F_12
	case glfw.KEY_F13:            return .F_13
	case glfw.KEY_F14:            return .F_14
	case glfw.KEY_F15:            return .F_15
	case glfw.KEY_F16:            return .F_16
	case glfw.KEY_F17:            return .F_17
	case glfw.KEY_F18:            return .F_18
	case glfw.KEY_F19:            return .F_19
	case glfw.KEY_F20:            return .F_20
	case glfw.KEY_F21:            return .F_21
	case glfw.KEY_F22:            return .F_22
	case glfw.KEY_F23:            return .F_23
	case glfw.KEY_F24:            return .F_24
	case glfw.KEY_F25:            return .F_25

	case glfw.KEY_KP_0:           return .KP_0
	case glfw.KEY_KP_1:           return .KP_1
	case glfw.KEY_KP_2:           return .KP_2
	case glfw.KEY_KP_3:           return .KP_3
	case glfw.KEY_KP_4:           return .KP_4
	case glfw.KEY_KP_5:           return .KP_5
	case glfw.KEY_KP_6:           return .KP_6
	case glfw.KEY_KP_7:           return .KP_7
	case glfw.KEY_KP_8:           return .KP_8
	case glfw.KEY_KP_9:           return .KP_9

	case glfw.KEY_KP_DECIMAL:     return .KP_Decimal
	case glfw.KEY_KP_DIVIDE:      return .KP_Divide
	case glfw.KEY_KP_MULTIPLY:    return .KP_Multiply
	case glfw.KEY_KP_SUBTRACT:    return .KP_Subtract
	case glfw.KEY_KP_ADD:         return .KP_Add
	case glfw.KEY_KP_ENTER:       return .KP_Enter
	case glfw.KEY_KP_EQUAL:       return .KP_Equal

	case glfw.KEY_LEFT_SHIFT:     return .Left_Shift
	case glfw.KEY_LEFT_CONTROL:   return .Left_Control
	case glfw.KEY_LEFT_ALT:       return .Left_Alt
	case glfw.KEY_LEFT_SUPER:     return .Left_Super
	case glfw.KEY_RIGHT_SHIFT:    return .Right_Shift
	case glfw.KEY_RIGHT_CONTROL:  return .Right_Control
	case glfw.KEY_RIGHT_ALT:      return .Right_Alt
	case glfw.KEY_RIGHT_SUPER:    return .Right_Super
	case glfw.KEY_MENU:           return .Menu
	case:                         return .Unknown
	}
}

Mouse_Button :: enum u8 {
	Unknown,

	Button_1,
	Button_2,
	Button_3,
	Button_4,
	Button_5,
	Button_6,
	Button_7,
	Button_8,

	Left   = Button_1,
	Right  = Button_2,
	Middle = Button_3,
}

_map_glfw_mouse_button :: proc "contextless" (glfw_mouse_button: i32) -> Mouse_Button {
	switch glfw_mouse_button {
 	case glfw.MOUSE_BUTTON_1:  return .Button_1
 	case glfw.MOUSE_BUTTON_2:  return .Button_2
 	case glfw.MOUSE_BUTTON_3:  return .Button_3
 	case glfw.MOUSE_BUTTON_4:  return .Button_4
 	case glfw.MOUSE_BUTTON_5:  return .Button_5
 	case glfw.MOUSE_BUTTON_6:  return .Button_6
 	case glfw.MOUSE_BUTTON_7:  return .Button_7
 	case glfw.MOUSE_BUTTON_8:  return .Button_8
	case:                      return .Unknown
	}
}

Input :: struct {
	pressed_keys: bit_set[Key],
	pressed_mouse_buttons: bit_set[Mouse_Button],
	cursor_position: [2]f64,
	cursor_position_delta: [2]f64,
}

_input: Input

_init_input :: proc() {
	x, y := glfw.GetCursorPos(_window.handle)
	_input.cursor_position = { x, y }
}

_input_new_frame :: proc() {
	_input.cursor_position_delta = 0
}

_input_update_cursor_pos :: proc() {
	pos_x, pos_y := glfw.GetCursorPos(_window.handle)
	_input.cursor_position = { pos_x, pos_y }
}

@(require_results)
key_pressed :: proc(key: Key) -> bool {
	return key in _input.pressed_keys
}

@(require_results)
mouse_button_pressed :: proc(button: Mouse_Button) -> bool {
	return button in _input.pressed_mouse_buttons
}

@(require_results)
cursor_position :: proc() -> [2]f64 {
	return _input.cursor_position
}

@(require_results)
cursor_position_delta :: proc() -> [2]f64 {
	return _input.cursor_position_delta
}

Key_Pressed_Event :: struct {
	key: Key,
}

Key_Released_Event :: struct {
	key: Key,
}

@(private)
_glfw_key_callback :: proc "c" (window_handle: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = _context
	key := _map_glfw_key(key)
	if action == glfw.PRESS {
		_input.pressed_keys += { key }
		_push_event(Key_Pressed_Event{ key })
	} else if action == glfw.RELEASE {
		_input.pressed_keys -= { key }
		_push_event(Key_Released_Event{ key })
	}
}

Mouse_Button_Pressed_Event :: struct {
	button: Mouse_Button,
}

Mouse_Button_Released_Event :: struct {
	button: Mouse_Button,
}

@(private)
_glfw_mouse_button_callback :: proc "c" (window_handle: glfw.WindowHandle, button, action, mods: i32) {
	context = _context
	button := _map_glfw_mouse_button(button)
	if action == glfw.PRESS {
		_input.pressed_mouse_buttons += { button }
		_push_event(Mouse_Button_Pressed_Event{ button })
	} else if action == glfw.RELEASE {
		_input.pressed_mouse_buttons -= { button }
		_push_event(Mouse_Button_Released_Event{ button })
	}
}

@(private)
_glfw_cursor_position_callback :: proc "c" (window_handle: glfw.WindowHandle, xpos, ypos: f64) {
	position := [2]f64{ xpos, ypos }
	_input.cursor_position_delta += (position - _input.cursor_position)
	_input.cursor_position = position
}

_init_imgui :: proc() {
	imgui.CHECKVERSION()
	imgui.CreateContext()

	io := imgui.GetIO()
	io.ConfigFlags += { .DockingEnable, .ViewportsEnable }
	io.FontGlobalScale = IMGUI_FONT_SCALE

	imgui_impl_glfw.InitForOpenGL(_window.handle, install_callbacks = true)
	imgui_impl_opengl3.Init("#version 430 core")
}

_deinit_imgui :: proc() {
	imgui_impl_opengl3.Shutdown()
	imgui_impl_glfw.Shutdown()
	imgui.DestroyContext()
}

_imgui_new_frame :: proc() {
	imgui_impl_opengl3.NewFrame()
	imgui_impl_glfw.NewFrame()
	imgui.NewFrame()
	viewport := imgui.GetMainViewport()
	imgui.DockSpaceOverViewport(imgui.GetID("Main window dock space"), viewport, { .PassthruCentralNode })
}

_imgui_render :: proc() {
	imgui.Render()
	imgui_impl_opengl3.RenderDrawData(imgui.GetDrawData())
	imgui.UpdatePlatformWindows()
	imgui.RenderPlatformWindowsDefault()
	glfw.MakeContextCurrent(_window.handle)
}

@(require_results)
gl_index :: proc($I: typeid) -> u32 {
	when I == u8 {
		return gl.UNSIGNED_BYTE
	} else when I == u16 {
		return gl.UNSIGNED_SHORT
	} else when I == u32 {
		return gl.UNSIGNED_INT
	} else {
		#panic("T cannot be used for indexing in OpenGL.")
	}
}

Shader :: struct {
	id: u32,
}

create_shader :: proc(vertex_source, fragment_source: string,
					  tess_control_source := "",
					  tess_evaluation_source := "",
					  geometry_source := "") -> (shader: Shader, ok := false) {
	vertex_shader := create_sub_shader(vertex_source, gl.VERTEX_SHADER) or_return
	defer gl.DeleteShader(vertex_shader)
	fragment_shader := create_sub_shader(fragment_source, gl.FRAGMENT_SHADER) or_return
	defer gl.DeleteShader(fragment_shader)

	tess_control_shader := u32(gl.NONE)
	tess_evaluation_shader := u32(gl.NONE)
	geometry_shader := u32(gl.NONE)
	if tess_control_source != "" {
		tess_control_shader = create_sub_shader(tess_control_source, gl.TESS_CONTROL_SHADER) or_return
	}
	defer gl.DeleteShader(tess_control_shader)
	if tess_evaluation_source != "" {
		tess_evaluation_shader = create_sub_shader(tess_evaluation_source, gl.TESS_EVALUATION_SHADER) or_return
	}
	defer gl.DeleteShader(tess_evaluation_shader)
	if geometry_source != "" {
		geometry_shader = create_sub_shader(geometry_source, gl.GEOMETRY_SHADER) or_return
	}
	defer gl.DeleteShader(geometry_shader)

	shader.id = link_shader_program(vertex_shader,
									fragment_shader,
									tess_control_shader,
									tess_evaluation_shader,
									geometry_shader) or_return

	ok = true
	return
}

create_shader_from_files :: proc(vertex_path, fragment_path: string,
								 tess_control_path := "",
								 tess_evaluation_path := "",
								 geometry_path := "") -> (shader: Shader, ok := false) {
	read_shader_source :: proc(shader_type: string, path: string) -> (source: string, ok := false) {
		file_data, error := os.read_entire_file(path, context.temp_allocator)
		if error != nil {
			log.errorf("Failed to read %v shader source from file `%v`: %v", shader_type, path, error)
			return
		}
		source = cast(string)file_data
		return
	}

	vertex_source := read_shader_source("vertex", vertex_path) or_return
	fragment_source := read_shader_source("fragment", fragment_path) or_return

	tess_control_source := ""
	tess_evaluation_source := ""
	geometry_source := ""

	if tess_control_path != "" {
		tess_control_source = read_shader_source("tess control", tess_control_path) or_return
	}
	if tess_evaluation_path != "" {
		tess_evaluation_source = read_shader_source("tess evaluation", tess_evaluation_path) or_return
	}
	if geometry_path != "" {
		geometry_source = read_shader_source("geometry", geometry_path) or_return
	}

	return create_shader(vertex_source = vertex_source,
						 fragment_source = fragment_source,
						 tess_control_source = tess_control_source,
						 tess_evaluation_source = tess_evaluation_source,
						 geometry_source = geometry_source)
}

destroy_shader :: proc(shader: Shader) {
	gl.DeleteProgram(shader.id)
}

use_shader :: proc(shader: Shader) {
	gl.UseProgram(shader.id)
}

create_sub_shader :: proc(shader_source: string, shader_type: u32) -> (shader: u32, ok := false) {
	shader_type_string :: proc(type: u32) -> string {
		switch type {
		case gl.VERTEX_SHADER: return "vertex"
		case gl.FRAGMENT_SHADER: return "fragment"
		case gl.TESS_CONTROL_SHADER: return "tess control"
		case gl.TESS_EVALUATION_SHADER: return "tess evaluation"
		case gl.GEOMETRY_SHADER: return "geometry"
		case gl.COMPUTE_SHADER: return "compute"
		}

		assert(false)
		return "unknown"
	}

	sources_array := [1]cstring{ cast(cstring)raw_data(shader_source) }
	lengths_array := [1]i32{ cast(i32)len(shader_source) }

	shader = gl.CreateShader(shader_type)
	gl.ShaderSource(shader, 1, raw_data(sources_array[:]), raw_data(lengths_array[:]))
	gl.CompileShader(shader)

	is_compiled: i32
	if gl.GetShaderiv(shader, gl.COMPILE_STATUS, &is_compiled); is_compiled == i32(gl.FALSE) {
		info_log_length: i32
		gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &info_log_length)
		info_log_buffer := make([]byte, info_log_length, context.temp_allocator)
		gl.GetShaderInfoLog(shader, info_log_length, nil, raw_data(info_log_buffer))
		info_log := string(info_log_buffer)
		info_log = strings.trim_null(info_log)

		log.errorf("Failed to compile %v shader: %v", shader_type_string(shader_type), info_log)
		gl.DeleteShader(shader)
		return
	}

	ok = true
	return
}

link_shader_program :: proc(vertex_shader,
							fragment_shader,
							tess_control_shader,
							tess_evaluation_shader,
							geometry_shader: u32) -> (program: u32, ok := false) {
	program = gl.CreateProgram()

	gl.AttachShader(program, vertex_shader)
	gl.AttachShader(program, fragment_shader)
	if tess_control_shader != gl.NONE do gl.AttachShader(program, tess_control_shader)
	if tess_evaluation_shader != gl.NONE do gl.AttachShader(program, tess_evaluation_shader)
	if geometry_shader != gl.NONE do gl.AttachShader(program, geometry_shader)
	gl.LinkProgram(program)

	is_linked: i32
	if gl.GetProgramiv(program, gl.LINK_STATUS, &is_linked); is_linked == i32(gl.FALSE) {
		info_log_length: i32
		gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &info_log_length)
		info_log_buffer := make([]byte, info_log_length, context.temp_allocator)
		gl.GetProgramInfoLog(program, info_log_length, nil, raw_data(info_log_buffer))
		info_log := string(info_log_buffer)
		info_log = strings.trim_null(info_log)

		log.errorf("Failed to link shader: %v", info_log)
		gl.DeleteProgram(program)
		return
	}

	gl.DetachShader(program, vertex_shader)
	gl.DetachShader(program, fragment_shader)
	if tess_control_shader != gl.NONE do gl.DetachShader(program, tess_control_shader)
	if tess_evaluation_shader != gl.NONE do gl.DetachShader(program, tess_evaluation_shader)
	if geometry_shader != gl.NONE do gl.DetachShader(program, geometry_shader)

	ok = true
	return
}

Uniform :: struct($T: typeid) {
	location: i32,
}

@(require_results)
get_uniform :: proc(shader: Shader, uniform: cstring, $T: typeid) -> (Uniform(T), bool) #optional_ok {
	location := gl.GetUniformLocation(shader.id, uniform)
	when ODIN_DEBUG { if location == -1 do log.warnf("Uniform \"%v\" does not exist!", uniform) }
	return Uniform(T) { location }, location != -1
}

set_uniform :: proc(shader: Shader, uniform: Uniform($T), value: T) {
	location := uniform.location
	when ODIN_DEBUG { if location == -1 do log.warnf("No uniform at location %v.", location) }

	when T == i32 {
		gl.ProgramUniform1i(shader.id, location, value)
	} else when T == f32 {
		gl.ProgramUniform1f(shader.id, location, value)
	} else when T == Vec2 {
		gl.ProgramUniform2f(shader.id, location, value.x, value.y)
	} else when T == Vec3 {
		gl.ProgramUniform3f(shader.id, location, value.x, value.y, value.z)
	} else when T == Vec4 {
		gl.ProgramUniform4f(shader.id, location, value.x, value.y, value.z, value.w)
	} else when T == Mat3 {
		value := value
		gl.ProgramUniformMatrix3fv(shader.id, location, 1, false, raw_data(&value))
	} else when T == Mat4 {
		value := value
		gl.ProgramUniformMatrix4fv(shader.id, location, 1, false, raw_data(&value))
	} else {
 		#panic("Type T not implemented for set_uniform.")
	}
}

Vertex_Array :: struct {
	id: u32,
}

create_vertex_array :: proc(va: ^Vertex_Array) {
	gl.CreateVertexArrays(1, &va.id)
}

destroy_vertex_array :: proc(va: ^Vertex_Array) {
	gl.DeleteVertexArrays(1, &va.id)
}

bind_vertex_array :: proc(va: Vertex_Array) {
	gl.BindVertexArray(va.id)
}

Vertex_Attribute :: enum {
	Float_1,
	Float_2,
	Float_3,
	Float_4,
}

Vertex_Attribute_Description :: struct {
	count: i32,
	type: u32,
	size: u32,
}

describe_vertex_attribute :: proc(attribute: Vertex_Attribute) -> Vertex_Attribute_Description {
	switch attribute {
	case .Float_1:
		return { 1, gl.FLOAT, 1 * size_of(f32) }
	case .Float_2:
		return { 2, gl.FLOAT, 2 * size_of(f32) }
	case .Float_3:
		return { 3, gl.FLOAT, 3 * size_of(f32) }
	case .Float_4:
		return { 4, gl.FLOAT, 4 * size_of(f32) }
	case:
		assert(false)
		return {}
	}
}

set_vertex_array_format :: proc(va: Vertex_Array, format: []Vertex_Attribute) {
	offset: u32 = 0

	for attribute, index in format {
		description := describe_vertex_attribute(attribute)

		gl.EnableVertexArrayAttrib(va.id, u32(index));
		gl.VertexArrayAttribFormat(va.id,
								   u32(index),
								   description.count,
								   description.type,
								   gl.FALSE,
								   offset)
		gl.VertexArrayAttribBinding(va.id, u32(index), 0)

		offset += description.size
	}
}

bind_vertex_buffer :: proc(va: Vertex_Array, buffer: Gl_Buffer, stride: i32) {
	gl.VertexArrayVertexBuffer(va.id,
							   bindingindex = 0,
							   buffer = buffer.id,
							   offset = 0,
							   stride = stride)
}

bind_index_buffer :: proc(va: Vertex_Array, buffer: Gl_Buffer) {
	gl.VertexArrayElementBuffer(va.id,
								buffer = buffer.id)
}

// Buffers can be either static or dynamic.
// Static buffers have a fixed size.
// Dynamic buffers have a dynamic size.
Gl_Buffer :: struct {
	id: u32,
	size: int,
}

create_static_gl_buffer :: proc(buffer: ^Gl_Buffer, size: int) {
	gl.CreateBuffers(1, &buffer.id)
	gl.NamedBufferStorage(buffer.id, size, nil, gl.DYNAMIC_STORAGE_BIT)
	buffer.size = size
}

create_static_gl_buffer_with_data :: proc(buffer: ^Gl_Buffer, data: []byte) {
	gl.CreateBuffers(1, &buffer.id)
	data_size := slice.size(data)
	gl.NamedBufferStorage(buffer.id, data_size, raw_data(data), gl.DYNAMIC_STORAGE_BIT)
	buffer.size = data_size
}

upload_static_gl_buffer_data :: proc(buffer: Gl_Buffer, data: []byte, offset := 0) {
	data_size := slice.size(data)
	assert(offset + data_size <= buffer.size)
	gl.NamedBufferSubData(buffer.id, offset, data_size, raw_data(data))
}

create_dynamic_gl_buffer :: proc(buffer: ^Gl_Buffer, size := 0, usage: u32 = gl.DYNAMIC_DRAW) {
	gl.CreateBuffers(1, &buffer.id)
	gl.NamedBufferData(buffer.id, size, nil, usage)
	buffer.size = size
}

create_dynamic_gl_buffer_with_data :: proc(buffer: ^Gl_Buffer, data: []byte, usage: u32 = gl.DYNAMIC_DRAW) {
	gl.CreateBuffers(1, &buffer.id)
	data_size := slice.size(data)
	gl.NamedBufferData(buffer.id, data_size, raw_data(data), usage)
	buffer.size = data_size
}

upload_dynamic_gl_buffer_data :: proc(buffer: ^Gl_Buffer, data: []byte, usage: u32 = gl.DYNAMIC_DRAW) {
	data_size := slice.size(data)
	reserve_dynamic_gl_buffer_size(buffer, data_size, usage)
	gl.NamedBufferSubData(buffer.id, 0, data_size, raw_data(data))
}

reserve_dynamic_gl_buffer_size :: proc(buffer: ^Gl_Buffer, min_size: int, usage: u32 = gl.DYNAMIC_DRAW) {
	// We can't just create a new buffer and copy the old data into it, because we want the id of the buffer to
	// remain the same. So we copy the data into a temporary buffer, initialize the new data store for the buffer
	// and copy over the data from the temporary buffer back into the old buffer.

	if buffer.size >= min_size do return

	new_size := max(buffer.size + buffer.size / 2, min_size)

	if buffer.size == 0 {
		// No need to do any copying.
		gl.NamedBufferData(buffer.id, new_size, nil, usage)
		buffer.size = new_size
		return
	}

	temp_buffer: Gl_Buffer
	create_static_gl_buffer(&temp_buffer, buffer.size)
	defer destroy_gl_buffer(&temp_buffer)

	gl.CopyNamedBufferSubData(readBuffer = buffer.id,
							  writeBuffer = temp_buffer.id,
							  readOffset = 0,
							  writeOffset = 0,
							  size = buffer.size)

	gl.NamedBufferData(buffer.id, new_size, nil, usage)

	gl.CopyNamedBufferSubData(readBuffer = temp_buffer.id,
							  writeBuffer = buffer.id,
							  readOffset = 0,
							  writeOffset = 0,
							  size = buffer.size)

	buffer.size = new_size
}

destroy_gl_buffer :: proc(buffer: ^Gl_Buffer) {
	gl.DeleteBuffers(1, &buffer.id)
}

bind_uniform_buffer :: proc(buffer: Gl_Buffer, binding_point: u32) {
	gl.BindBufferBase(gl.UNIFORM_BUFFER, binding_point, buffer.id)
}

bind_shader_storage_buffer :: proc(buffer: Gl_Buffer, binding_point: u32) {
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, binding_point, buffer.id)
}

Texture_Parameters :: struct {
	wrap_s: i32,
	wrap_t: i32,
	min_filter: i32,
	mag_filter: i32,
	internal_format: u32,
}

DEFAULT_TEXTURE_PARAMETERS :: Texture_Parameters {
	wrap_s = gl.REPEAT,
	wrap_t = gl.REPEAT,
	min_filter = gl.LINEAR_MIPMAP_LINEAR,
	mag_filter = gl.LINEAR,
	internal_format = gl.RGBA8,
}

Texture :: struct {
	id: u32,
	width: u32,
	height: u32,
}

create_texture :: proc(width, height: u32,
					   channels: int,
					   pixels: []byte,
					   texture_parameters := DEFAULT_TEXTURE_PARAMETERS) -> (texture: Texture) {
	assert(slice.size(pixels) == int(width) * int(height) * channels * size_of(byte))
	gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.id)

	gl.TextureParameteri(texture.id, gl.TEXTURE_WRAP_S, texture_parameters.wrap_s)
	gl.TextureParameteri(texture.id, gl.TEXTURE_WRAP_T, texture_parameters.wrap_t)
	gl.TextureParameteri(texture.id, gl.TEXTURE_MIN_FILTER, texture_parameters.min_filter)
	gl.TextureParameteri(texture.id, gl.TEXTURE_MAG_FILTER, texture_parameters.mag_filter)

	gl.TextureStorage2D(texture.id,
						levels = 1,
						internalformat = texture_parameters.internal_format,
						width = i32(width),
						height = i32(height))

	gl.TextureSubImage2D(texture.id,
						 level = 0,
						 xoffset = 0,
						 yoffset = 0,
						 width = i32(width),
						 height = i32(height),
						 format = gl_texture_format_from_channels(channels),
						 type = gl.UNSIGNED_BYTE,
						 pixels = raw_data(pixels))

	texture.width, texture.height = width, height
	return
}

create_texture_from_png_in_memory :: proc(png_file_data: []byte,
										  texture_parameters := DEFAULT_TEXTURE_PARAMETERS) -> (texture: Texture,
																								ok := false) {
	img, error := image.load(png_file_data, {}, context.temp_allocator)
	if error != nil {
		log.errorf("Failed to load image from png file in memory: %v", error)
		return
	}
	defer image.destroy(img, context.temp_allocator)

	texture = create_texture(u32(img.width),
							 u32(img.height),
							 img.channels,
							 bytes.buffer_to_bytes(&img.pixels),
							 texture_parameters)
	ok = true
	return
}

create_texture_from_png_file :: proc(path: string,
									 texture_parameters := DEFAULT_TEXTURE_PARAMETERS) -> (texture: Texture,
																						   ok := false) {
	file_data, file_error := os.read_entire_file(path, context.temp_allocator)
	if file_error != nil {
		log.errorf("Failed to load image from png file `%v`: %v", path, file_error)
		return
	}
	assert(strings.to_lower(filepath.ext(path), context.temp_allocator) == ".png", "expected a png file")
	return create_texture_from_png_in_memory(file_data, texture_parameters)
}

create_texture_from_jpeg_in_memory :: proc(jpeg_file_data: []byte,
										   texture_parameters := DEFAULT_TEXTURE_PARAMETERS) -> (texture: Texture,
																								 ok := false) {
	img, error := image.load(jpeg_file_data, {}, context.temp_allocator)
	if error != nil {
		log.errorf("Failed to load image from jpeg file in memory: %v", error)
		return
	}
	defer image.destroy(img, context.temp_allocator)

	texture = create_texture(u32(img.width),
							 u32(img.height),
							 img.channels,
							 bytes.buffer_to_bytes(&img.pixels),
							 texture_parameters)
	ok = true
	return
}

create_texture_from_jpeg_file :: proc(path: string,
									  texture_parameters := DEFAULT_TEXTURE_PARAMETERS) -> (texture: Texture,
																							ok := false) {
	file_data, file_error := os.read_entire_file(path, context.temp_allocator)
	if file_error != nil {
		log.errorf("Failed to load image from jpeg file `%v`: %v", path, file_error)
		return
	}
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	assert(extension == ".jpg" || extension == ".jpeg", "expected a jpeg file")
	return create_texture_from_jpeg_in_memory(file_data, texture_parameters)
}

destroy_texture :: proc(texture: ^Texture) {
	gl.DeleteTextures(1, &texture.id)
}

bind_texture :: proc(texture: Texture, slot: u32) {
	gl.BindTextureUnit(slot, texture.id)
}

gl_texture_format_from_channels :: proc(#any_int channels: int) -> u32 {
	switch channels {
	case 1: return gl.RED
	case 2: return gl.RG
	case 3: return gl.RGB
	case 4: return gl.RGBA
	}

	assert(false)
	return gl.NONE
}

UP   :: Vec3{ 0,  1, 0 }
DOWN :: Vec3{ 0, -1, 0 }

Camera :: struct {
	position: Vec3,
	yaw: f32,
	pitch: f32,
}

Camera_Vectors :: struct {
	forward: Vec3,
	right: Vec3,
	up: Vec3,
}

@(require_results)
camera_vectors :: proc(camera: Camera) -> Camera_Vectors {
	forward: Vec3
	forward.x = math.cos(camera.yaw) * math.cos(camera.pitch)
	forward.y = math.sin(camera.pitch)
	forward.z = math.sin(camera.yaw) * math.cos(camera.pitch)
	forward = linalg.normalize(forward)
	right := linalg.normalize(linalg.cross(forward, UP))
	up := linalg.normalize(linalg.cross(right, forward))

	return Camera_Vectors {
		forward = forward,
		right = right,
		up = up,
	}
}

Mesh_Data :: struct($V: typeid, $I: typeid) {
	vertex_format: [dynamic; 16]Vertex_Attribute,
	vertex_stride: u32,
	index_type: u32,
	vertices: [dynamic]V,
	indices: [dynamic]I,
}

free_mesh_data :: proc(mesh_data: $M/Mesh_Data) {
	delete(mesh_data.vertices)
	delete(mesh_data.indices)
}

Mesh :: struct {
	vertex_array: Vertex_Array,
	buffer: Gl_Buffer, // Contains both the vertices and indices.
	vertex_count: u32,
	index_type: u32,
	index_data_offset: u32,
}

create_mesh_from_vertices_and_indices :: proc(vertices: []byte,
											  vertex_stride: u32,
											  vertex_format: []Vertex_Attribute,
											  indices: []byte, // indices can be nil.
											  index_type: u32) -> (mesh: Mesh) {
	vertex_data_offset := 0
	index_data_offset := slice.size(vertices[:])
	buffer_size := slice.size(vertices[:]) + slice.size(indices[:])

	create_static_gl_buffer(&mesh.buffer, buffer_size)
	upload_static_gl_buffer_data(mesh.buffer, vertices, vertex_data_offset)
	upload_static_gl_buffer_data(mesh.buffer, indices, index_data_offset)

	mesh.vertex_count = cast(u32)len(indices) if indices != nil else u32(slice.size(vertices[:])) / max(vertex_stride, 1)
	mesh.index_type = index_type
	mesh.index_data_offset = cast(u32)index_data_offset

	create_vertex_array(&mesh.vertex_array)
	set_vertex_array_format(mesh.vertex_array, vertex_format)
	bind_vertex_buffer(mesh.vertex_array, mesh.buffer, i32(vertex_stride))
	bind_index_buffer(mesh.vertex_array, mesh.buffer)
	return
}

create_mesh_from_obj :: proc(path: cstring) -> (mesh: Mesh, ok := false) {
	mesh_data := load_mesh_from_obj(path, context.temp_allocator) or_return
	mesh = create_mesh_from_mesh_data(&mesh_data)
	ok = true
	return
}

create_mesh_from_mesh_data :: proc(mesh_data: ^$M/Mesh_Data) -> (mesh: Mesh) {
	mesh = create_mesh_from_vertices_and_indices(vertices = slice.to_bytes(mesh_data.vertices[:]),
												 vertex_stride = mesh_data.vertex_stride,
												 vertex_format = mesh_data.vertex_format[:],
												 indices = slice.to_bytes(mesh_data.indices[:]),
												 index_type = mesh_data.index_type)
	return
}

create_mesh :: proc{ create_mesh_from_vertices_and_indices, create_mesh_from_obj, create_mesh_from_mesh_data }

load_mesh_from_obj :: proc(path: cstring,
						   allocator := context.allocator) -> (mesh_data: Mesh_Data(Vertex_3D, u32), ok := false) {
	file_reader :: proc "c" (ctx: rawptr,
							 filename: cstring,
							 is_mtl: c.int,
							 obj_filename: cstring,
							 buf: ^[^]c.char,
							 buf_len: ^c.size_t) {
		context = _context
		data, error := os.read_entire_file(cast(string)obj_filename, context.temp_allocator)
		if error != nil {
			log.errorf("Failed to read obj file `%v`: %v", obj_filename, error)
			buf^ = nil
			buf_len^ = 0
			return
		}
		buf^ = raw_data(data)
		buf_len^ = len(data)
		return
	}

	attrib: tinyobj.attrib_t
	shapes_data: [^]tinyobj.shape_t
	num_shapes: uint
	materials_data: [^]tinyobj.material_t
	num_materials: uint

	if tinyobj.parse_obj(attrib = &attrib,
						 shapes = &shapes_data,
						 num_shapes = &num_shapes,
						 materials = &materials_data,
						 num_materials = &num_materials,
						 file_name = path,
						 file_reader = file_reader,
						 ctx = nil,
						 flags = tinyobj.FLAG_TRIANGULATE) != tinyobj.SUCCESS {
		return
	}
	defer {
		tinyobj.attrib_free(&attrib)
		tinyobj.shapes_free(shapes_data, num_shapes)
		tinyobj.materials_free(materials_data, num_materials)
	}

	Mesh_Vertex :: Vertex_3D
	mesh_vertex_format := vertex_3d_format
	Mesh_Index :: u32

	append(&mesh_data.vertex_format, ..mesh_vertex_format)
	mesh_data.vertex_stride = size_of(Mesh_Vertex)
	mesh_data.index_type = gl_index(Mesh_Index)
	mesh_data.vertices = make([dynamic]Mesh_Vertex, allocator)
	mesh_data.indices = make([dynamic]Mesh_Index, allocator)
	defer if !ok do free_mesh_data(mesh_data)

	num_triangles := attrib.num_face_num_verts
	model_vertices := attrib.faces[:num_triangles * 3]
	unique_vertex_indices := make(map[Mesh_Vertex]Mesh_Index, context.temp_allocator)
	for vertex in model_vertices {
		vertex := Mesh_Vertex {
			position = Vec3{
				attrib.vertices[vertex.v_idx * 3 + 0],
				attrib.vertices[vertex.v_idx * 3 + 1],
				attrib.vertices[vertex.v_idx * 3 + 2],
			},
			normal = Vec3{
				attrib.normals[vertex.vn_idx * 3 + 0],
				attrib.normals[vertex.vn_idx * 3 + 1],
				attrib.normals[vertex.vn_idx * 3 + 2],
			},
			uv = Vec2{
				attrib.texcoords[vertex.vt_idx * 2 + 0],
				attrib.texcoords[vertex.vt_idx * 2 + 1],
			},
		}

		if vertex_index, vertex_index_ok := unique_vertex_indices[vertex]; vertex_index_ok {
			append(&mesh_data.indices, vertex_index)
		} else {
			vertex_index = cast(Mesh_Index)len(unique_vertex_indices)
			unique_vertex_indices[vertex] = vertex_index
			append(&mesh_data.vertices, vertex)
			append(&mesh_data.indices, vertex_index)
		}
	}

	ok = true
	return
}

destroy_mesh :: proc(mesh: ^Mesh) {
	destroy_vertex_array(&mesh.vertex_array)
	destroy_gl_buffer(&mesh.buffer)
}

bind_mesh :: proc(mesh: Mesh) {
	bind_vertex_array(mesh.vertex_array)
}

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Mat3 :: matrix[3, 3]f32
Mat4 :: matrix[4, 4]f32

Vertex_3D :: struct {
	position: Vec3,
	normal: Vec3,
	uv: Vec2,
}

@(rodata) vertex_3d_format := []Vertex_Attribute{ .Float_3, .Float_3, .Float_2 }

WHITE       :: Vec4{ 1, 1, 1, 1 }
BLACK       :: Vec4{ 0, 0, 0, 1 }
TRANSPARENT :: Vec4{ 0, 0, 0, 0 }

RED         :: Vec4{ 1, 0, 0, 1 }
GREEN       :: Vec4{ 0, 1, 0, 1 }
BLUE        :: Vec4{ 0, 0, 1, 1 }
