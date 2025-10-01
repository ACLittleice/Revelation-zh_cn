#define SSRT_MAX_SAMPLES 20 // [4 8 12 16 18 20 24 28 32 36 40 48 64 128 256 512]
#define SSRT_SKY_TRACING

#define SSRT_REFINEMENT
#define SSRT_REFINEMENT_STEPS 6 // [2 3 4 5 6 7 8 9 10 12 14 16 18 20 22 24 26 28 30 32]

#define SSRT_ADAPTIVE_STEP

//================================================================================================//

#if defined PASS_SPECULAR_LIGHTING
#define loadDepthMacro loadDepth0
#define loadDepthMacroDH loadDepth0DH
#else
#define loadDepthMacro loadDepth1
#define loadDepthMacroDH loadDepth1DH
#endif

bool ScreenSpaceRaytrace(in vec3 viewPos, in vec3 viewDir, in float dither, in uint steps, inout vec3 rayPos) {
	if (viewDir.z > max0(-viewPos.z)) return false;

    float rSteps = 1.0 / float(steps);

    vec3 endPos = ViewToScreenSpace(viewDir + viewPos);
    vec3 rayDir = normalize(endPos - rayPos);
    float stepNorm = 1.0 / rayDir.z;

	float stepLength = minOf((step(0.0, rayDir) - rayPos) / rayDir) * rSteps;

    rayDir.xy *= viewSize;
    rayPos.xy *= viewSize;

    vec3 rayStep = rayDir * stepLength;
    rayPos += rayStep * dither;

    #if defined DISTANT_HORIZONS
        float screenDepthMax = ViewToScreenDepth(ScreenToViewDepthDH(1.0));
    #else
        #define screenDepthMax 1.0
    #endif

	bool hit = false;

    for (uint i = 0u; i < steps; ++i, rayPos += rayStep) {
        if (clamp(rayPos.xy, vec2(0.0), viewSize) != rayPos.xy) break;

        #ifndef SSRT_SKY_TRACING
            if (rayPos.z >= screenDepthMax) break;
        #endif

        float sampleDepth = loadDepthMacro(ivec2(rayPos.xy));
        #if defined DISTANT_HORIZONS
            if (sampleDepth > 1.0 - EPS) sampleDepth = ViewToScreenDepth(ScreenToViewDepthDH(loadDepthMacroDH(ivec2(rayPos.xy))));
        #endif

		if (rayPos.z > sampleDepth) {
			float sampleViewDepth = ScreenToViewDepth(sampleDepth);
			float traceViewDepth = ScreenToViewDepth(rayPos.z);

            if (traceViewDepth - sampleViewDepth > 0.2 * traceViewDepth) {
                hit = true;
                break;
            }
        }

        #ifdef SSRT_ADAPTIVE_STEP
            rayStep = rayDir * clamp((sampleDepth - rayPos.z) * stepNorm, 1e-2 * rSteps, rSteps);
        #endif
    }

    // Refine hit position (binary search)
    #ifdef SSRT_REFINEMENT
	if (hit) {
        for (uint i = 0u; i < SSRT_REFINEMENT_STEPS; ++i) {
            rayStep *= 0.5;

            float sampleDepth = loadDepthMacro(ivec2(rayPos.xy));
            #if defined DISTANT_HORIZONS
                if (sampleDepth > 1.0 - EPS) sampleDepth = ViewToScreenDepth(ScreenToViewDepthDH(loadDepthMacroDH(ivec2(rayPos.xy))));
            #endif

            rayPos += rayStep * (step(rayPos.z, sampleDepth) * 2.0 - 1.0);
        }
    }
    #endif

    return hit;
}