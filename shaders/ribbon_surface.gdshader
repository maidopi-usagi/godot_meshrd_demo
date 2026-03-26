shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform float roughness_value : hint_range(0.0, 1.0) = 0.1;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.9;
uniform float emission_strength : hint_range(0.0, 5.0) = 2.5;

varying float v_hue;

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void vertex() {
	v_hue = CUSTOM0.x;
	NORMAL = normalize(-VERTEX);
}

void fragment() {
	vec3 col = hsv2rgb(vec3(v_hue, 0.85, 1.0));
	ALBEDO = col;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	EMISSION = col * emission_strength;
}
