
//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 6,7,8 */
layout (location = 0) out vec4 albedoOut;
layout (location = 1) out uvec4 materialOut;
layout (location = 2) out vec4 normalOut;

//======// Uniform //=============================================================================//

uniform sampler2D tex;

//======// Input //===============================================================================//

in vec3 worldPos;

in vec4 vertColor;
in vec2 texCoord;
in vec2 lightmap;

//======// Function //============================================================================//

float bayer2 (vec2 a) { a = 0.5 * floor(a); return fract(1.5 * fract(a.y) + a.x); }
#define bayer4(a) (bayer2(0.5 * (a)) * 0.25 + bayer2(a))

//======// Main //================================================================================//
void main() {
	vec4 albedo = texture(tex, texCoord) * vertColor;

	if (albedo.a < 0.1) { discard; return; }

	#ifdef WHITE_WORLD
		albedo.rgb = vec3(1.0);
	#endif

	albedoOut = vec4(albedo.rgb, 1.0);

	materialOut.x = PackupDithered2x8U(lightmap, bayer4(gl_FragCoord.xy));
	materialOut.y = lightmap.x > 0.99 ? 20u : 40u;
	materialOut.zw = uvec2(0);

	vec3 flatNormal = normalize(cross(dFdx(worldPos), dFdy(worldPos)));

	normalOut.xy = OctEncodeUnorm(flatNormal);
	normalOut.zw = normalOut.xy;
}