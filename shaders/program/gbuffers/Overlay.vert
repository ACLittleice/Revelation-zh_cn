
//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

flat out vec4 vertColor;
out vec2 texCoord;

//======// Attribute //===========================================================================//

in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;

//======// Uniform //=============================================================================//

uniform vec3 chunkOffset;

uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat4 textureMatrix = mat4(1.0);

uniform vec2 taaOffset;

//======// Main //================================================================================//
void main() {
	vec3 viewPos = transMAD(modelViewMatrix, vaPosition + chunkOffset);
	gl_Position = diagonal4(projectionMatrix) * viewPos.xyzz + projectionMatrix[3];

	#ifdef TAA_ENABLED
		gl_Position.xy += taaOffset * gl_Position.w;
	#endif

	vertColor = vaColor;
    texCoord = mat2(textureMatrix) * vaUV0 + textureMatrix[3].xy;
}