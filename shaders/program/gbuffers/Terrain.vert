
//======// Fix for https://github.com/HaringPro/Revelation/issues/18 //===========================//

in ivec2 vaUV2;

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

#define WAVING_FOLIAGE
#define WAVING_FOLIAGE_SPEED 0.5 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 2.0 3.0 5.0 7.0 10.0]
#define WAVING_FOLIAGE_STRENGTH 0.1 // [0.0 0.01 0.02 0.03 0.04 0.05 0.06 0.08 0.1 0.12 0.14 0.16 0.18 0.2 0.22 0.24 0.26 0.28 0.3 0.33 0.36 0.4 0.43 0.46 0.5 0.55 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 2.0]
#define UNLABELLED_FOILAGE_DETECTION

//======// Output //==============================================================================//

flat out uint normalPack;
#if defined NORMAL_MAPPING
flat out uvec2 tangentPack;
#endif

out vec3 vertColor;
out vec2 texCoord;
out vec2 lightmap;
flat out uint materialID;

#if defined PARALLAX || defined AUTO_GENERATED_NORMAL
	out vec2 tileBase;
	flat out vec2 tileScale;
	flat out vec2 tileOffset;
#endif

//======// Attribute //===========================================================================//

in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;
in vec3 vaNormal;

in vec4 mc_Entity;
in vec2 mc_midTexCoord;
in vec4 at_tangent;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Random.glsl"

//======// Main //================================================================================//
void main() {
	vertColor = vaColor.rgb;
	texCoord = vaUV0;

	#ifdef IS_IRIS
	    lightmap = saturate((vec2(vaUV2) - 8.0) * rcp(232.0));
	#else
		lightmap = saturate(vec2(vaUV2) * r240);
	#endif

	vec3 worldPos = transMAD(gbufferModelViewInverse, transMAD(modelViewMatrix, vaPosition + chunkOffset));

	materialID = uint(max(mc_Entity.x - 1e4, 1));

	// Encode normal and tangent
	vec3 normal = mat3(gbufferModelViewInverse) * normalize(normalMatrix * vaNormal);
	normalPack = packSnorm2x16(OctEncodeSnorm(normal));
	#if defined NORMAL_MAPPING
		vec3 tangent = mat3(gbufferModelViewInverse) * normalize(normalMatrix * at_tangent.xyz);
		tangentPack.x = packSnorm2x16(OctEncodeSnorm(tangent));
		tangentPack.y = (floatBitsToUint(at_tangent.w) & 0x80000000u) | 0x3F800000u;
	#endif

	#ifdef WAVING_FOLIAGE
		// Plants
		if (clamp(materialID, 1000u, 1002u) == materialID) {
			worldPos += cameraPosition;

			float time = frameTimeCounter * WAVING_FOLIAGE_SPEED;
			float windIntensity = cube(lightmap.y) * (wetness + 1.0) * WAVING_FOLIAGE_STRENGTH;
			float topVertex = step(vaUV0.y, mc_midTexCoord.y) + float(materialID == 1001u);

			float noise = textureBicubic(noisetex, (worldPos.xz + sin(time)) * 0.005).x * 4.0;

			float windOffset = sin(dot(worldPos.xz + time, vec2(2.0, 2.5)) + noise);
			worldPos.xz += vec2(0.6, 0.4) * windOffset * windIntensity * topVertex;

			worldPos -= cameraPosition;
		}

		// Leaves
		if (materialID == 13u) {
			worldPos += cameraPosition;

			float time = frameTimeCounter * WAVING_FOLIAGE_SPEED;
			float windIntensity = cube(lightmap.y) * (wetness + 1.0) * WAVING_FOLIAGE_STRENGTH;

			float noise = Pseudo3DNoise(worldPos * 2.0 + sin(time)) * 4.0;

			float windOffset = sin(dot(worldPos + time, vec3(2.0, 1.5, 2.5)) + noise);
			worldPos += vec3(0.2, 0.1, 0.3) * windOffset * windIntensity;

			worldPos -= cameraPosition;
		}
	#endif

	// Unlabelled foilage detection
	#ifdef UNLABELLED_FOILAGE_DETECTION
		if (materialID < 1u && maxOf(abs(vaNormal)) < 0.99) materialID = 1003u;
	#endif

	#if defined PARALLAX || defined AUTO_GENERATED_NORMAL
		vec2 minMidCoord = texCoord - mc_midTexCoord;
		tileBase = signI(minMidCoord) * 0.5 + 0.5;
		tileScale = abs(minMidCoord) * 2.0;
		tileOffset = min(texCoord, mc_midTexCoord - minMidCoord);
	#endif

	gl_Position = diagonal4(projectionMatrix) * transMAD(gbufferModelView, worldPos).xyzz + projectionMatrix[3];

	#ifdef TAA_ENABLED
		gl_Position.xy += taaOffset * gl_Position.w;
	#endif
}