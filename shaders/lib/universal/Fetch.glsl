vec3 FetchGeometryNormal(in ivec2 texel) {
	return OctDecodeUnorm(loadNormalPack(texel).xy);
}

vec3 FetchSurfaceNormal(in ivec2 texel) {
	return OctDecodeUnorm(loadNormalPack(texel).zw);
}

void FetchNormalData(in ivec2 texel, out vec3 geometryNormal, out vec3 surfaceNormal) {
	vec4 pack = loadNormalPack(texel);
	geometryNormal = OctDecodeUnorm(pack.xy);

	#if defined MC_NORMAL_MAP || defined PASS_TRANSLUCENT
		surfaceNormal = OctDecodeUnorm(pack.zw);
	#else
		surfaceNormal = geometryNormal;
	#endif
}

vec4 ExtractSpecularTex(in uvec4 pack) {
	return vec4(Unpack2x8U(pack.z), Unpack2x8U(pack.w));
}