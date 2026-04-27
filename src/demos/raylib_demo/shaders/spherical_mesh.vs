#version 330

in vec3 vertexPosition;
in vec4 vertexColor;

uniform vec4 u_rect;
uniform vec2 u_screen;
uniform vec3 u_camera_pos;
uniform float u_yaw;
uniform float u_pitch;
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

vec4 tangentAt(vec4 origin, vec3 localDir) {
    float step = max(u_radius * 0.003, 0.02);
    vec4 p = sceneAmbient(u_camera_pos + localDir * step);
    vec4 tangent = p - origin * dot(origin, p);
    float len = length(tangent);
    if (len <= 0.00001) return vec4(0.0);
    return tangent / len;
}

void cameraFrame(out vec4 origin, out vec4 right, out vec4 up, out vec4 forward) {
    origin = sceneAmbient(u_camera_pos);

    vec3 localRight = vec3(cos(u_yaw), 0.0, sin(u_yaw));
    vec3 localForward = vec3(-sin(u_yaw), 0.0, cos(u_yaw));
    vec3 localUp = vec3(0.0, 1.0, 0.0);

    right = tangentAt(origin, localRight);
    vec4 flatForward = tangentAt(origin, localForward);
    vec4 flatUp = tangentAt(origin, localUp);

    forward = normalize(flatForward * cos(u_pitch) + flatUp * sin(u_pitch));
    up = normalize(flatUp * cos(u_pitch) - flatForward * sin(u_pitch));
}

vec3 relativeDirection(vec4 point, vec4 right, vec4 up, vec4 forward) {
    vec3 rel = vec3(dot(point, right), dot(point, up), dot(point, forward));
    float len = max(length(rel), 0.00001);
    return rel / len;
}

vec2 projectStereographicDirection(vec3 dir) {
    float denom = max(1.0 + dir.z, 0.0001);
    vec2 raw = dir.xy * (2.0 / denom);
    float aspect = max(u_rect.z / max(u_rect.w * 2.0, 1.0), 0.001);
    return vec2(raw.x * u_zoom / aspect, raw.y * u_zoom);
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
    vec4 origin;
    vec4 right;
    vec4 up;
    vec4 forward;
    cameraFrame(origin, right, up, forward);

    vec4 point = sceneAmbient(vertexPosition);
    vec3 nearDir = relativeDirection(point, right, up, forward);
    float selectedSide = (u_far_pass == 0) ? nearDir.z : -nearDir.z;
    fragPassSide = selectedSide;

    if (u_far_pass != 0) {
        origin = -origin;
        forward = -forward;
    }

    vec3 dir = relativeDirection(point, right, up, forward);
    vec2 rectSpace = projectStereographicDirection(dir);

    float w = clamp(dot(sceneAmbient(u_camera_pos), point), -1.0, 1.0);
    float distance = acos(w) * max(u_radius, 0.001);
    fragDepth = clamp(distance / (PI * max(u_radius, 0.001)), 0.0, 1.0);
    fragColor = vertexColor;

    if (selectedSide < -0.02) {
        gl_Position = vec4(3.0, 3.0, 1.0, 1.0);
        return;
    }

    gl_Position = clipFromRectSpace(rectSpace, fragDepth);
}
