#version 330

uniform sampler2D texture0;
uniform vec4 colDiffuse;

in vec2 fragTexCoord;
in vec4 fragColor;
in float fragDepth;

out vec4 finalColor;

void main() {
    vec4 albedo = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    finalColor = vec4(albedo.rgb, fragDepth);
}
