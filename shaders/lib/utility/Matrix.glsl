
mat4 BuildOrthoMat(float left, float right, float bottom, float top, float near, float far) {
    float rw = rcp(left - right);
    float rh = rcp(bottom - top);
    float rd = rcp(near - far);

    return mat4(
        -2.0 * rw, 0.0, 0.0, 0.0,
        0.0, -2.0 * rh, 0.0, 0.0,
        0.0, 0.0, 2.0 * rd, 0.0,
        (left + right) * rw, (bottom + top) * rh, (near + far) * rd, 1.0
    );
}

mat4 BuildOrthoMat(float width, float height, float near, float far) {
    float rw = rcp(width);
    float rh = rcp(height);
    float rd = rcp(near - far);

    return mat4(
        -2.0 * rw, 0.0, 0.0, 0.0,
        0.0, -2.0 * rh, 0.0, 0.0,
        0.0, 0.0, 2.0 * rd, 0.0,
        0.0, 0.0, (near + far) * rd, 1.0
    );
}

mat4 BuildPerspectiveMat(float fov, float aspect, float near, float far) {
    float f = 1.0 / tan(fov * (PI / 180.0));
    float rd = rcp(near - far);

    return mat4(
        f / aspect, 0.0, 0.0, 0.0,
        0.0, f, 0.0, 0.0,
        0.0, 0.0, (near + far) * rd, -1.0,
        0.0, 0.0, near * far * rd * 2.0, 0.0
    );
}

mat3 ConstructTBN(vec3 n) {
	vec3 b = normalize(vec3(0.0, n.z, -n.y));
	return mat3(cross(b, n), b, n);
}

mat2 rotateMat(float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return mat2(cosine, -sine, sine, cosine);
}

mat3 rotateMatX(float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return mat3(1.0, 0.0, 0.0, 0.0, cosine, -sine, 0.0, sine, cosine);
}

mat3 rotateMatY(float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return mat3(cosine, 0.0, sine, 0.0, 1.0, 0.0, -sine, 0.0, cosine);
}

mat3 rotateMatZ(float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return mat3(cosine, -sine, 0.0, sine, cosine, 0.0, 0.0, 0.0, 1.0);
}
