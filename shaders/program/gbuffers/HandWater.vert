
//======// Fix for https://github.com/HaringPro/Revelation/issues/18 //===========================//

in ivec2 vaUV2;

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

flat out uint normalPack;
#if defined NORMAL_MAPPING
flat out uvec2 tangentPack;
#endif

out vec4 vertColor;
out vec2 texCoord;
out vec2 lightmap;

//======// Attribute //===========================================================================//

in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;
in vec3 vaNormal;

in vec4 at_tangent;

//======// Uniform //=============================================================================//

uniform vec3 chunkOffset;

uniform mat3 normalMatrix;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;

uniform mat4 gbufferModelViewInverse;

uniform vec2 taaOffset;

//======// Main //================================================================================//
void main() {
	vertColor = vaColor;
	texCoord = vaUV0;

	lightmap = saturate(vec2(vaUV2) * r240);

	vec3 viewPos = transMAD(modelViewMatrix, vaPosition + chunkOffset);
	// worldPos = transMAD(gbufferModelViewInverse, viewPos);
	gl_Position = diagonal4(projectionMatrix) * viewPos.xyzz + projectionMatrix[3];

	#ifdef TAA_ENABLED
		gl_Position.xy += taaOffset * gl_Position.w;
	#endif

	// Encode normal and tangent
	vec3 normal = mat3(gbufferModelViewInverse) * normalize(normalMatrix * vaNormal);
	normalPack = packSnorm2x16(OctEncodeSnorm(normal));
	#if defined NORMAL_MAPPING
		vec3 tangent = mat3(gbufferModelViewInverse) * normalize(normalMatrix * at_tangent.xyz);
		tangentPack.x = packSnorm2x16(OctEncodeSnorm(tangent));
		tangentPack.y = (floatBitsToUint(at_tangent.w) & 0x80000000u) | 0x3F800000u;
	#endif
}