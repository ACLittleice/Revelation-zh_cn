
//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 7 */
layout (location = 0) out uvec4 materialOut;

//======// Input //===============================================================================//

in vec4 vertColor;
in vec2 texCoord;
in vec2 lightmap;

//======// Uniform //=============================================================================//

uniform sampler2D tex;

//======// Function //============================================================================//

float bayer2 (vec2 a) { a = 0.5 * floor(a); return fract(1.5 * fract(a.y) + a.x); }
#define bayer4(a) (bayer2(0.5 * (a)) * 0.25 + bayer2(a))

//======// Main //================================================================================//
void main() {
	vec4 albedo = texture(tex, texCoord) * vertColor;

	if (albedo.a < 0.1) { discard; return; }

	materialOut.x = PackupDithered2x8U(lightmap, bayer4(gl_FragCoord.xy));
	materialOut.y = 500u;

	materialOut.z = Packup2x8U(albedo.xy);
	materialOut.w = Packup2x8U(albedo.zw);
}