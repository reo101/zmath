#version 330

in vec4 fragColor;
in float fragDepth;
in float fragPassSide;

out vec4 finalColor;

void main() {
    if (fragPassSide < -0.001) discard;

    float shade = mix(0.72, 1.0, 1.0 - fragDepth);
    finalColor = vec4(fragColor.rgb * shade, fragColor.a);
    gl_FragDepth = fragDepth;
}
