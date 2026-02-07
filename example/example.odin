package example

import glue ".."
import gl "vendor:OpenGL"

import "core:log"
import "core:slice"

Vertex :: struct {
	position: [2]f32,
	uv: [2]f32,
}

@(rodata)
vertex_format := [?]glue.Vertex_Attribute{
	.Float_2,
	.Float_2,
}

VERTEX_SOURCE ::
`
#version 460 core

layout (location = 0) in vec2 in_position;
layout (location = 1) in vec2 in_uv;

out vec2 UV;

void main() {
	UV = in_uv;
	gl_Position = vec4(in_position, 0.0, 1.0);
}
`

FRAGMENT_SOURCE ::
`
#version 460 core

in vec2 UV;

out vec4 out_color;

layout (binding = 0) uniform sampler2D texture_0;

void main() {
	out_color = texture(texture_0, UV);
}
`

@(rodata)
vertices := [4]Vertex{
	{ position = { -0.5, -0.5 }, uv = { 0, 0 } },
	{ position = { -0.5,  0.5 }, uv = { 0, 1 } },
	{ position = {  0.5,  0.5 }, uv = { 1, 1 } },
	{ position = {  0.5, -0.5 }, uv = { 1, 0 } },
}

@(rodata)
indices := [6]u32{ 0, 1, 2, 0, 2, 3 }

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)
	defer log.destroy_console_logger(context.logger)

	if !glue.create_window(1920, 1080, "Example") do log.panic("Failed to create a window")
	defer glue.destroy_window()

	vertex_array: glue.Vertex_Array
	glue.create_vertex_array(&vertex_array)
	defer glue.destroy_vertex_array(&vertex_array)

	vertex_buffer: glue.Gl_Buffer
	glue.create_static_gl_buffer_with_data(&vertex_buffer, slice.to_bytes(vertices[:]))
	defer glue.destroy_gl_buffer(&vertex_buffer)

	index_buffer: glue.Gl_Buffer
	glue.create_static_gl_buffer_with_data(&index_buffer, slice.to_bytes(indices[:]))
	defer glue.destroy_gl_buffer(&index_buffer)

	shader, shader_ok := glue.create_shader(VERTEX_SOURCE, FRAGMENT_SOURCE)
	if !shader_ok do log.panic("Failed to compile the shader.")
	defer glue.destroy_shader(shader)

	texture, texture_ok := glue.create_texture_from_jpeg_file("container.jpg")
	if !texture_ok do log.panic("Failed to load the texture.")
	defer glue.destroy_texture(&texture)

	glue.bind_vertex_array(vertex_array)
	glue.set_vertex_array_format(vertex_array, vertex_format[:])
	glue.bind_vertex_buffer(vertex_array, vertex_buffer, size_of(Vertex))
	glue.bind_index_buffer(vertex_array, index_buffer)
	glue.use_shader(shader)
	glue.bind_texture(texture, 0)

	for !glue.window_should_close() {
		glue.poll_events()
		gl.DrawElements(gl.TRIANGLES, len(indices), glue.gl_index(u32), nil)
		glue.swap_buffers()
		free_all(context.temp_allocator)
	}
}
