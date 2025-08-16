#ifndef FORCE_DISABLE_SUBGROUP_OPS
    #if defined(MC_GL_KHR_shader_subgroup)
        #define SUBGROUP_OPS
    #endif
#endif

#ifdef SUBGROUP_OPS
    #ifdef MC_GL_VENDOR_AMD
        #define SCALARIZED_LOAD(a, b) (a) = subgroupBroadcastFirst(b)
    #else
        #define SCALARIZED_LOAD(a, b) if (subgroupElect()) { (a) = (b); }
    #endif
#endif