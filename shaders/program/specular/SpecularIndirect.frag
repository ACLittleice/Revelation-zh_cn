/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Compute specular reflections

--------------------------------------------------------------------------------
*/

#define PASS_SPECULAR_LIGHTING

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 3 */
out vec4 specularOut;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Struct //==============================================================================//

#include "/lib/universal/Material.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"

#include "/lib/atmosphere/Common.glsl"

#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
	#include "/lib/surface/BRDF.glsl"
	#include "/lib/surface/Reflection.glsl"
#endif

//======// Main //================================================================================//
void main() {
	specularOut = vec4(0.0);

	#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
		ivec2 screenTexel = ivec2(gl_FragCoord.xy);
		vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;
		vec3 screenPos = vec3(screenCoord, FetchDepthFix(screenTexel));

		if (screenPos.z > 1.0 - EPS) discard;

		Material material = GetMaterialData(loadGbufferData1(screenTexel).xy);

		// Specular reflections
		if (material.specularMask) {
			vec3 viewPos = ScreenToViewSpace(screenPos);

			#if defined DISTANT_HORIZONS
				bool dhTerrainMask = screenPos.z > 1.0 - EPS;
				if (dhTerrainMask) {
					screenPos.z = loadDepth0DH(screenTexel);
					viewPos = ScreenToViewSpaceDH(screenPos);
				}
			#endif

			vec3 worldPos = mat3(gbufferModelViewInverse) * viewPos;
			vec3 worldDir = normalize(worldPos);
			worldPos += gbufferModelViewInverse[3].xyz;

			uvec4 gbufferData0 = loadGbufferData0(screenTexel);
			vec3 worldNormal = FetchWorldNormal(gbufferData0);

			vec2 lightmap = Unpack2x8U(gbufferData0.x);
			lightmap.y = remap(0.3, 0.7, lightmap.y);

			float dither = BlueNoiseTemporal(screenTexel);
			specularOut = CalculateSpecularReflections(material, worldNormal, screenPos, worldDir, viewPos, lightmap.y, dither);
		}
	#endif
}