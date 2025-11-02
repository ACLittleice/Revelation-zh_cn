
//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 7,8,12 */
layout (location = 0) out uvec4 materialOut;
layout (location = 1) out vec4 normalOut;
layout (location = 2) out vec4 waterOut;

//======// Uniform //=============================================================================//

uniform sampler2D tex;

#if defined NORMAL_MAPPING
	uniform sampler2D normals;
#endif

#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
    uniform sampler2D specular;
#endif

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Input //===============================================================================//

flat in mat3 tbnMatrix;

in vec4 vertColor;
in vec2 texCoord;
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
	normalOut.xy = OctEncodeUnorm(tbnMatrix[2]);

	if (materialID == 3u) { // water
		ivec2 texel = ivec2(gl_FragCoord.xy);
		vec3 worldDir = normalize(worldPos - gbufferModelViewInverse[3].xyz);

		#ifdef PHYSICS_OCEAN
			WavePixelData wave = physics_wavePixel(physics_localPosition.xz, physics_localWaviness, physics_iterationsNormal, physics_gameTime);

			vec3 worldNormal = wave.normal;
		#else
			vec3 minecraftPos = worldPos + cameraPosition;
			#ifdef WATER_PARALLAX
				float dither = SampleStbnVec1(texel, frameCounter + 5);
				vec3 worldNormal = CalculateWaterNormal(minecraftPos, worldDir * tbnMatrix, dither);
			#else
				vec3 worldNormal = CalculateWaterNormal(minecraftPos);
			#endif

			worldNormal = tbnMatrix * worldNormal;
		#endif

		float depth1 = loadDepth1(texel);
		vec3 viewPos1 = ScreenToViewSpace(vec3(gl_FragCoord.xy * viewPixelSize, depth1));
		vec3 worldPos1 = transMAD(gbufferModelViewInverse, viewPos1);

		vec2 encodedNormal = OctEncodeUnorm(worldNormal);
		normalOut.zw = encodedNormal;

		waterOut = vec4(distance(worldPos, worldPos1) * r255, Packup2x8(encodedNormal), 0.0, 1.0);
	} else {
		vec4 albedo = texture(tex, texCoord) * vertColor;

		if (albedo.a < 0.1) { discard; return; }

		#if defined NORMAL_MAPPING
			vec3 normalTex = texture(normals, texCoord).rgb;
			DecodeNormalTex(normalTex);
			normalOut.zw = OctEncodeUnorm(tbnMatrix * normalTex);
		#else
			normalOut.zw = normalOut.xy;
		#endif

		materialOut.z = Packup2x8U(albedo.xy);
		materialOut.w = Packup2x8U(albedo.zw);
		waterOut = vec4(0.0);
	}

	materialOut.x = PackupDithered2x8U(lightmap, bayer4(gl_FragCoord.xy));
	materialOut.y = materialID;
}