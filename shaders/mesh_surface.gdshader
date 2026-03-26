shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float visualization_mode = 0.0;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.05;
uniform float metallic_value : hint_range(0.0, 1.0) = 1.0;
uniform float height_min = -1.0;
uniform float height_max = 1.0;
uniform vec4 low_color : source_color = vec4(0.05, 0.12, 0.18, 1.0);
uniform vec4 mid_color : source_color = vec4(0.17, 0.49, 0.23, 1.0);
uniform vec4 high_color : source_color = vec4(0.83, 0.78, 0.56, 1.0);
uniform vec4 rock_color : source_color = vec4(0.44, 0.39, 0.34, 1.0);

varying float local_height;

void vertex() {
	local_height = VERTEX.y;
	if (length(CUSTOM0.xyz) > 0.0001) {
		NORMAL = normalize(CUSTOM0.xyz);
	}
}

void fragment() {
	vec3 albedo = albedo_tint.rgb;
	if (visualization_mode > 0.5) {
		float height_t = smoothstep(height_min, height_max, local_height);
		float low_mix = smoothstep(0.08, 0.5, height_t);
		float high_mix = smoothstep(0.55, 0.92, height_t);
		float slope = 1.0 - clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);
		albedo = mix(low_color.rgb, mid_color.rgb, low_mix);
		albedo = mix(albedo, high_color.rgb, high_mix);
		albedo = mix(albedo, rock_color.rgb, slope * 0.65);
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
}