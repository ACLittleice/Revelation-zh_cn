
#define PASS_DH_WATER

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 7,8,12 */
layout (location = 0) out uvec4 gbufferOut0;
layout (location = 1) out vec4 gbufferOut1;
layout (location = 2) out vec4 waterOut;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Input //===============================================================================//

flat in vec3 flatNormal;

in vec4 vertColor;
in vec2 lightmap;
flat in uint materialID;

in vec3 worldPos;

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Random.glsl"

#define PHYSICS_OCEAN_SUPPORT

#ifdef PHYSICS_OCEAN
	#define PHYSICS_FRAGMENT
	#include "/lib/water/PhysicsOceans.glsl"
#else
	#include "/lib/water/WaterWave.glsl"
#endif

//======// Main //================================================================================//
void main() {
    if (loadDepth0(ivec2(gl_FragCoord.xy)) < 1.0) { discard; return; }

	vec3 worldNormal;

	if (materialID == 3u) { // water
		vec3 worldDir = normalize(worldPos - gbufferModelViewInverse[3].xyz);

		#ifdef PHYSICS_OCEAN
			WavePixelData wave = physics_wavePixel(physics_localPosition.xz, physics_localWaviness, physics_iterationsNormal, physics_gameTime);

			worldNormal = wave.normal;
		#else
			mat3 tbnMatrix = ConstructTBN(flatNormal);

			vec3 minecraftPos = worldPos + cameraPosition;
			vec2 tangentPos = ((minecraftPos * vec3(1.0, 0.15, 1.0)) * tbnMatrix).xy;
			#ifdef WATER_PARALLAX
				float dither = SampleStbnVec1(ivec2(gl_FragCoord.xy), frameCounter + 4);
				worldNormal = CalculateWaterNormal(tangentPos, worldDir * tbnMatrix, dither);
			#else
				worldNormal = CalculateWaterNormal(tangentPos);
			#endif

			worldNormal = tbnMatrix * worldNormal;
		#endif

		// Water normal clamp
		worldNormal = normalize(worldNormal + flatNormal * inversesqrt(4.0 * abs(dot(flatNormal, worldDir)) + 1e-2));

		float depth1 = loadDepth1DH(ivec2(gl_FragCoord.xy));
		vec3 viewPos1 = ScreenToViewSpace(vec3(gl_FragCoord.xy * viewPixelSize, depth1));
		vec3 worldPos1 = transMAD(gbufferModelViewInverse, viewPos1);

		waterOut = vec4(distance(worldPos, worldPos1) * rcp(64.0), lightmap.y, 0.0, 1.0);
	} else {
		gbufferOut1 = vertColor;
		worldNormal = flatNormal;
		waterOut = vec4(0.0);
	}

	gbufferOut0.x = PackupDithered2x8U(lightmap, bayer4(gl_FragCoord.xy));
	gbufferOut0.y = materialID;
	gbufferOut0.z = Packup2x8U(OctEncodeUnorm(flatNormal));
	gbufferOut0.w = Packup2x8U(OctEncodeUnorm(worldNormal));
}