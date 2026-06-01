#version 330

in vec3 vertexPosition;
in vec4 vertexColor;

uniform vec4 u_rect;
uniform vec2 u_screen;
uniform vec4 u_camera_origin;
uniform vec4 u_camera_right;
uniform vec4 u_camera_up;
uniform vec4 u_camera_forward;
uniform float u_radius;
uniform float u_zoom;
uniform int u_far_pass;

out vec4 fragColor;
out float fragDepth;
out float fragPassSide;

const float PI = 3.14159265358979323846;

vec4 sceneAmbient(vec3 p) {
    float radius = max(u_radius, 0.001);
    float groundLen = length(p.xz);

    vec4 base;
    if (groundLen <= 0.00001) {
        base = vec4(1.0, 0.0, 0.0, 0.0);
    } else {
        float theta = groundLen / radius;
        float scale = sin(theta) / groundLen;
        base = vec4(cos(theta), p.x * scale, 0.0, p.z * scale);
    }

    float heightTheta = p.y / radius;
    vec4 up = vec4(0.0, 0.0, 1.0, 0.0);
    return normalize(base * cos(heightTheta) + up * sin(heightTheta));
}

vec4 relativeCoords(vec4 point, vec4 origin, vec4 right, vec4 up, vec4 forward) {
    return vec4(
        dot(point, origin),
        dot(point, right),
        dot(point, up),
        dot(point, forward)
    );
}

vec2 projectConformalModel(vec4 rel) {
    float denom = 1.0 + rel.x;
    if (abs(denom) <= 0.0001) return vec2(1.0e9, 1.0e9);
    vec2 model = rel.yz / denom;
    float aspect = max(u_rect.z / max(u_rect.w * 2.0, 1.0), 0.001);
    return vec2(model.x * u_zoom / aspect, model.y * u_zoom);
}

vec4 clipFromRectSpace(vec2 rectSpace, float depth01) {
    vec2 pixel = vec2(
        u_rect.x + (rectSpace.x * 0.5 + 0.5) * u_rect.z,
        u_rect.y + (0.5 - rectSpace.y * 0.5) * u_rect.w
    );
    vec2 clip = vec2(pixel.x / u_screen.x * 2.0 - 1.0, 1.0 - pixel.y / u_screen.y * 2.0);
    return vec4(clip, depth01 * 2.0 - 1.0, 1.0);
}

void main() {
    vec4 origin = normalize(u_camera_origin);
    vec4 right = normalize(u_camera_right);
    vec4 up = normalize(u_camera_up);
    vec4 forward = normalize(u_camera_forward);

    vec4 point = sceneAmbient(vertexPosition);
    vec4 nearRel = relativeCoords(point, origin, right, up, forward);
    float selectedSide = (u_far_pass == 0) ? nearRel.w : -nearRel.w;
    fragPassSide = selectedSide;

    if (u_far_pass != 0) {
        origin = -origin;
        forward = -forward;
    }

    vec4 rel = relativeCoords(point, origin, right, up, forward);
    vec2 rectSpace = projectConformalModel(rel);

    float w = clamp(dot(u_camera_origin, point), -1.0, 1.0);
    float distance = acos(w) * max(u_radius, 0.001);
    fragDepth = clamp(distance / (PI * max(u_radius, 0.001)), 0.0, 1.0);
    fragColor = vertexColor;

    if (selectedSide < -0.02) {
        gl_Position = vec4(3.0, 3.0, 1.0, 1.0);
        return;
    }

    gl_Position = clipFromRectSpace(rectSpace, fragDepth);
}
