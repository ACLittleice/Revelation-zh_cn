float FetchDepthFix(in ivec2 texel) {
	float depth = loadDepth0(texel);
	return depth + 0.38 * step(depth, 0.56);
}

float FetchDepthSoildFix(in ivec2 texel) {
	float depth = loadDepth1(texel);
	return depth + 0.38 * step(depth, 0.56);
}

vec3 FetchFlatNormal(in uvec4 data) {
	return OctDecodeUnorm(Unpack2x8U(data.z));
}

vec3 FetchWorldNormal(in uvec4 data) {
	#if defined NORMAL_MAPPING
		return OctDecodeUnorm(Unpack2x8U(data.w));
	#else
		return OctDecodeUnorm(Unpack2x8U(data.z));
	#endif
}

vec3 FetchWorldNormal(in ivec2 texel) {
	#if defined NORMAL_MAPPING
		return OctDecodeUnorm(Unpack2x8U(loadGbufferData0(texel).w));
	#else
		return OctDecodeUnorm(Unpack2x8U(loadGbufferData0(texel).z));
	#endif
}

vec3 FetchWorldNormal(in uint data) {
	return OctDecodeUnorm(Unpack2x8U(data));
}