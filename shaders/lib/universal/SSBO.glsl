
layout (std430, binding = 0) buffer GlobalData {
    float prevWorldTime;
    vec3 directIlluminance;
    vec3 skyIlluminance;
    vec3[9] skySH;
} global;

layout (std430, binding = 1) buffer ExposureData {
    uint histogram[HISTOGRAM_BIN_COUNT];
    float value;
} exposure;
