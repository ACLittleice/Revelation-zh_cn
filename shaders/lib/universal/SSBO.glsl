
struct LightData {
    vec3 directIlluminance;
    vec3 skyIlluminance;
    vec3[9] skySH;
};

struct ExposureData {
    uint histogram[HISTOGRAM_BIN_COUNT];
    float value;
};

layout (std430, binding = 0) buffer GlobalData {
    LightData light;
    ExposureData exposure;
    float prevWorldTime;
} global;
