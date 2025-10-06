// Reference:
// Morgan McGuire, Michael Mara. "Efficient GPU Screen-Space Ray Tracing". JCGT, 2014.
// https://jcgt.org/published/0003/04/04/paper.pdf

#define SSRT_MAX_SAMPLES 20 // [4 8 12 16 18 20 24 28 32 36 40 48 64 128 256 512]
#define SSRT_SKY_TRACING

// #define SSRT_REFINEMENT
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

// Referred from https://github.com/zombye/spectrum/blob/master/shaders/include/fragment/raytracer.fsh
// MIT License
float AscribeDepth(in float depth, in float zThickness) {
    depth = depth * 2.0 - 1.0;
    depth = (depth - zThickness * gbufferProjection[2].z) / (1.0 + zThickness);
    return depth * 0.5 + 0.5;
}

bool ScreenSpaceRaytrace(in vec3 viewPos, in vec3 viewDir, in float dither, in uint steps, inout vec3 rayPos) {
	if (viewDir.z > max0(-viewPos.z)) return false;

    float rSteps = 1.0 / float(steps);

    vec3 endPos = ViewToScreenSpace(viewDir + viewPos);
    vec3 rayDir = normalize(endPos - rayPos);
    float stepNorm = abs(1.0 / rayDir.z);

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

	float zThickness = 8.0 * viewPixelSize.y * gbufferProjectionInverse[1].y;

	bool hit = false;

    for (uint i = 0u; i < steps && !hit; ++i, rayPos += rayStep) {
        if (clamp(rayPos.xy, vec2(0.0), viewSize) != rayPos.xy) break;

        #ifndef SSRT_SKY_TRACING
            if (rayPos.z >= screenDepthMax) break;
        #endif

        float sampleDepth = loadDepthMacro(ivec2(rayPos.xy));
        #if defined DISTANT_HORIZONS
            if (sampleDepth > 1.0 - EPS) sampleDepth = ViewToScreenDepth(ScreenToViewDepthDH(loadDepthMacroDH(ivec2(rayPos.xy))));
        #endif

		if (rayPos.z > sampleDepth) {
            #ifdef SSRT_REFINEMENT
                // Refine hit position (binary search)
                vec3 refineStep = rayStep * 0.5;
                for (uint i = 0u; i < SSRT_REFINEMENT_STEPS; ++i, refineStep *= 0.5) {
                    rayPos += refineStep * fastSign(sampleDepth - rayPos.z);

                    sampleDepth = loadDepthMacro(ivec2(rayPos.xy));
                    #if defined DISTANT_HORIZONS
                        if (sampleDepth > 1.0 - EPS) sampleDepth = ViewToScreenDepth(ScreenToViewDepthDH(loadDepthMacroDH(ivec2(rayPos.xy))));
                    #endif
                }

                if (rayPos.z < sampleDepth) continue;
            #endif

            float ascribedDepth = AscribeDepth(sampleDepth, zThickness);
            if (ascribedDepth > rayPos.z - abs(rayStep.z)) {
                rayPos.z = sampleDepth;
                hit = true;
            }
        }

        #ifdef SSRT_ADAPTIVE_STEP
            rayStep = rayDir * clamp(abs(sampleDepth - rayPos.z) * stepNorm, 1e-2 * rSteps, stepLength);
        #endif
    }

    return hit;
}