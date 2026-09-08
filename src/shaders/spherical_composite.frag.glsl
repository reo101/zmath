#version 330

uniform sampler2D texture0;
uniform sampler2D u_mesh_texture;
uniform float u_mesh_enabled;

in vec2 fragTexCoord;

out vec4 finalColor;

void main() {
    vec4 analytic = texture(texture0, fragTexCoord);
    vec4 mesh = texture(u_mesh_texture, fragTexCoord);
    if (u_mesh_enabled > 0.5 && mesh.a > analytic.a) {
        finalColor = vec4(mesh.rgb, 1.0);
    } else {
        finalColor = vec4(analytic.rgb, 1.0);
    }
}
