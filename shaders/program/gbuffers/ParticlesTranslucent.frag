
//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 7,8 */
layout (location = 0) out uvec4 gbufferOut0;
layout (location = 1) out vec4 gbufferOut1;

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

	gbufferOut0.x = PackupDithered2x8U(lightmap, bayer4(gl_FragCoord.xy));
	gbufferOut0.y = 1000u;

    gbufferOut1 = albedo;
}