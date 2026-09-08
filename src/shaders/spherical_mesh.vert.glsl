#version 330

const float PI = 3.14159265358979323846;

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;

uniform mat4 matModel;
uniform vec2 u_resolution;
uniform float u_tan_half_fov;
uniform float u_world_radius;
uniform vec4 u_origin;
uniform vec4 u_right;
uniform vec4 u_up;
uniform vec4 u_forward;
uniform vec4 u_mesh_center;
uniform vec4 u_mesh_basis_x;
uniform vec4 u_mesh_basis_y;
uniform vec4 u_mesh_basis_z;

out vec2 fragTexCoord;
out vec4 fragColor;
out float fragDepth;

vec4 tangentPoint(vec3 q) {
    float lengthQ = length(q);
    vec4 tangent = u_mesh_basis_x * q.x + u_mesh_basis_y * q.y + u_mesh_basis_z * q.z;
    if (lengthQ < 0.000001) return u_mesh_center;
    float angle = lengthQ / u_world_radius;
    return u_mesh_center * cos(angle) + tangent * (sin(angle) / lengthQ);
}

void main() {
    vec3 q = (matModel * vec4(vertexPosition, 1.0)).xyz;
    vec4 point = tangentPoint(q);
    float cosine = dot(point, u_origin);
    float x = dot(point, u_right);
    float y = dot(point, u_up);
    float denominator = max(0.000001, 1.0 + cosine);
    vec2 uv = vec2(x, y) / (denominator * u_tan_half_fov);
    float aspect = u_resolution.x / u_resolution.y;
    float baseAspect = 1280.0 / 720.0;

    gl_Position = vec4(uv.x * baseAspect / aspect, uv.y, -cosine, 1.0);
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragDepth = (cosine + 1.0) * 0.5;
}
