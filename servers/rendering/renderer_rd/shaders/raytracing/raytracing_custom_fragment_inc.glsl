// Custom shader fragment setup for RT hit groups (closest-hit and any-hit).
// Include inside main() under #ifdef RT_CUSTOM_HIT_GROUP.
//
// Required variables before inclusion:
//   uint  rt_geometry_idx   -- geometry/material index
//   vec3  rt_hit_pos        -- world-space hit position
//   vec2  rt_uv             -- interpolated UV
//   vec3  rt_normal         -- world-space geometry normal (flipped for back-face)
//   vec3  rt_tangent        -- world-space tangent
//   vec3  rt_bitangent      -- world-space bitangent
//   bool  rt_front_face     -- true if front-face hit
//
// Required bindings/types:
//   materials[], CustomMaterialUniforms, scene_data_block

MaterialData rt_mat = materials[rt_geometry_idx];
CustomMaterialUniforms material = CustomMaterialUniforms(rt_mat.uniform_address);

// Map hit data to Godot Shader Language built-in names.
mat4 rt_view_matrix = transpose(mat4(scene_data_block.data.view_matrix[0],
		scene_data_block.data.view_matrix[1],
		scene_data_block.data.view_matrix[2],
		vec4(0.0, 0.0, 0.0, 1.0)));
vec3 vertex = (rt_view_matrix * vec4(rt_hit_pos, 1.0)).xyz;
vec2 uv_interp = rt_uv;
vec2 uv2_interp = rt_uv;
vec3 normal = rt_normal;
vec3 tangent = rt_tangent;
vec3 binormal = rt_bitangent;
vec3 view = -gl_WorldRayDirectionEXT;
vec4 color_interp = vec4(1.0);
bool rt_front_facing = rt_front_face;
vec2 rt_screen_uv = vec2(gl_LaunchIDEXT.xy) / vec2(gl_LaunchSizeEXT.xy);
vec4 rt_frag_coord = vec4(gl_LaunchIDEXT.xy, 0.0, 1.0);
float global_time = scene_data_block.data.time;
mat4 read_model_matrix = mat4(gl_ObjectToWorldEXT);
vec2 read_viewport_size = scene_data_block.data.viewport_size;
mat4 inv_view_matrix = transpose(mat4(scene_data_block.data.inv_view_matrix[0],
		scene_data_block.data.inv_view_matrix[1],
		scene_data_block.data.inv_view_matrix[2],
		vec4(0.0, 0.0, 0.0, 1.0)));
mat4 read_view_matrix = rt_view_matrix;

// Fragment outputs with sensible defaults.
vec3 albedo = vec3(1.0);
float alpha = 1.0;
float metallic = 0.0;
float roughness = 0.5;
float specular = 0.5;
vec3 emission = vec3(0.0);
vec3 normal_map = vec3(0.5, 0.5, 1.0);
float normal_map_depth = 1.0;
float ao = 1.0;
float ao_light_affect = 0.0;
vec3 backlight = vec3(0.0);
float sss_strength = 0.0;
float rim = 0.0;
float rim_tint = 0.0;
float clearcoat = 0.0;
float clearcoat_roughness = 0.0;
float anisotropy = 0.0;
vec2 anisotropy_flow = vec2(1.0, 0.0);
float alpha_scissor_threshold = 0.0;
float alpha_hash_scale = 1.0;

{
	/* RT_CUSTOM_FRAGMENT_CODE */
}
