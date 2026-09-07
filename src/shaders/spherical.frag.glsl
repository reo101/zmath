#version 330

const float PI = 3.14159265358979323846;
const float TAU = 6.28318530717958647692;

uniform vec2 u_resolution;
uniform float u_tan_half_fov;
uniform float u_world_radius;
uniform vec4 u_origin;
uniform vec4 u_right;
uniform vec4 u_up;
uniform vec4 u_forward;
uniform float u_ground_a;
uniform int u_object_count;

layout(std140) uniform ObjectBlock {
    vec4 object_normals[384];
    vec4 object_meta[384];
    vec4 object_colors[16];
    vec4 object_bounds[64];
};

struct BoxFace {
    vec4 normal;
    float positive;
    float tone;
    int part;
};

struct Hit {
    int surface;
    float c;
    float s;
    float brightness;
    int part;
    vec4 point;
};

float dot4(vec4 a, vec4 b) {
    return dot(a, b);
}

float positiveMod(float x, float y) {
    return x - y * floor(x / y);
}

float fastAtan2(float y, float x) {
    float ax = abs(x);
    float ay = abs(y);
    float mx = max(ax, ay);
    float mn = min(ax, ay);
    if (mx == 0.0) return 0.0;
    float t = mn / mx;
    float s = t * t;
    float atanT = t * (0.9998660 + s * (-0.3302995 + s * (0.180141 + s * (-0.085133 + s * 0.0208351))));
    float angle = ay > ax ? PI * 0.5 - atanT : atanT;
    if (x < 0.0) angle = PI - angle;
    if (y < 0.0) angle = -angle;
    return angle;
}

vec4 frameDirection(vec2 uv) {
    float r = length(uv);
    if (r < 0.000001) return u_forward;
    float t = r * u_tan_half_fov;
    float denom = 1.0 / (1.0 + t * t);
    float sinTheta = 2.0 * t * denom;
    float cosTheta = (1.0 - t * t) * denom;
    return u_forward * cosTheta + u_right * (sinTheta * uv.x / r) + u_up * (sinTheta * uv.y / r);
}

vec4 rayPoint(vec4 dir, float c, float s) {
    return u_origin * c + dir * s;
}

bool boxEntry(vec4 dir, BoxFace faces[6], int n, out float outC, out float outS, out float outTone, out int outPart) {
    float phis[12];
    int keys[12];
    bool satisfied[6];
    int nBounds = 0;
    int count = 0;
    int entryKey = 0;

    for (int k = 0; k < 6; ++k) {
        if (k >= n) break;
        float a = dot4(u_origin, faces[k].normal);
        float b = dot4(dir, faces[k].normal);
        if (abs(a) < 0.000001 && abs(b) < 0.000001) {
            satisfied[k] = true;
            count += 1;
            continue;
        }
        float r = fastAtan2(b, a);
        satisfied[k] = (a >= 0.0) == (faces[k].positive > 0.5);
        if (satisfied[k]) count += 1;
        phis[nBounds] = positiveMod(r - PI * 0.5, TAU);
        keys[nBounds] = k;
        nBounds += 1;
        phis[nBounds] = positiveMod(r + PI * 0.5, TAU);
        keys[nBounds] = k;
        nBounds += 1;
    }

    // The exact entry solver only needs a tiny ordered boundary list. This
    // insertion sort keeps the angular implementation identical to the CPU
    // version without paying a generic sort's machinery per pixel.
    for (int i = 1; i < 12; ++i) {
        if (i >= nBounds) break;
        float p = phis[i];
        int k = keys[i];
        int j = i - 1;
        while (j >= 0 && p < phis[j]) {
            phis[j + 1] = phis[j];
            keys[j + 1] = keys[j];
            j -= 1;
        }
        phis[j + 1] = p;
        keys[j + 1] = k;
    }

    float previous = 0.0;
    for (int i = 0; i < 12; ++i) {
        if (i >= nBounds) break;
        float phi = phis[i];
        int k = keys[i];
        if (phi > PI) break;
        if (count == n && previous > 0.0001) {
            outC = cos(previous);
            outS = sin(previous);
            outTone = faces[entryKey].tone;
            outPart = faces[entryKey].part;
            return true;
        }
        if (satisfied[k]) count -= 1;
        else count += 1;
        satisfied[k] = !satisfied[k];
        if (count == n) {
            entryKey = k;
        }
        previous = phi;
    }
    return false;
}

void consider(float c, float s, float tone, int part, inout bool hit, inout float bestC, inout float bestS, inout float bestTone, inout int bestPart) {
    if (!hit || s * bestC - c * bestS < 0.0) {
        hit = true;
        bestC = c;
        bestS = s;
        bestTone = tone;
        bestPart = part;
    }
}

void traceData(vec4 dir, out Hit hit) {
    float bGround = dot4(dir, vec4(0.0, 0.0, 1.0, 0.0));
    float hGround = sqrt(bGround * bGround + u_ground_a * u_ground_a);
    float cosGround = -bGround / hGround;
    float sinGround = u_ground_a / hGround;

    bool objectHit = false;
    float cosObject = 0.0;
    float sinObject = 0.0;
    float objectTone = 0.0;
    int objectPart = 0;
    for (int object = 0; object < 64; ++object) {
        if (object >= u_object_count) break;
        vec4 bound = object_bounds[object];
        float boundCos = object_meta[object * 6].w;
        if (boundCos >= -0.5) {
            float boundA = dot4(u_origin, bound);
            float boundB = dot4(dir, bound);
            float reach = sqrt(boundA * boundA + boundB * boundB);
            if (reach < boundCos) continue;
            if (objectHit) {
                float bestBound = max(boundA, boundA * cosObject + boundB * sinObject);
                if (boundB >= 0.0 && sinObject * boundA - cosObject * boundB >= 0.0) {
                    bestBound = reach;
                }
                if (bestBound < boundCos) continue;
            }
        }
        BoxFace faces[6];
        int base = object * 6;
        for (int face = 0; face < 6; ++face) {
            vec4 meta = object_meta[base + face];
            faces[face] = BoxFace(object_normals[base + face], meta.x, meta.y, int(meta.z));
        }
        float c, s, tone;
        int part;
        if (boxEntry(dir, faces, 6, c, s, tone, part)) {
            consider(c, s, tone, 10 + part, objectHit, cosObject, sinObject, objectTone, objectPart);
        }
    }

    float cAlpha = cosGround;
    float sAlpha = sinGround;
    int surface = 0;
    int selectedPart = 0;
    float selectedTone = 0.0;
    if (objectHit && sinObject * cAlpha - cosObject * sAlpha < -0.0001) {
        cAlpha = cosObject;
        sAlpha = sinObject;
        surface = 3;
        selectedPart = objectPart;
        selectedTone = objectTone;
    }

    vec4 point = rayPoint(dir, cAlpha, sAlpha);
    vec4 tangent = dir * cAlpha - u_origin * sAlpha;
    float brightness = surface == 3 ? selectedTone : abs(dot4(tangent, vec4(0.0, 0.0, 1.0, 0.0)));
    hit.surface = surface;
    hit.c = cAlpha;
    hit.s = sAlpha;
    hit.brightness = clamp(brightness, 0.0, 1.0);
    hit.part = selectedPart;
    hit.point = point;
}

vec3 groundColor(vec4 point) {
    float walk = asin(clamp(dot4(point, vec4(0.0, 0.0, 0.0, 1.0)), -1.0, 1.0)) * u_world_radius;
    float strafe = fastAtan2(dot4(point, vec4(0.0, 1.0, 0.0, 0.0)), dot4(point, vec4(1.0, 0.0, 0.0, 0.0))) * u_world_radius;
    float checker = mod(floor(walk) + floor(strafe), 2.0);
    return checker < 0.5 ? vec3(92.0, 104.0, 96.0) / 255.0 : vec3(46.0, 54.0, 50.0) / 255.0;
}

void main() {
    vec2 uv = (gl_FragCoord.xy / u_resolution) * 2.0 - 1.0;
    uv.x *= u_resolution.x / u_resolution.y;
    uv.x /= 1280.0 / 720.0;
    Hit hit;
    if (length(uv) > 1.0) {
        gl_FragColor = vec4(4.0, 6.0, 10.0, 255.0) / 255.0;
        return;
    }
    vec4 dir = frameDirection(uv);
    traceData(dir, hit);
    float dim = 1.0 - 0.25 * (1.0 - hit.c) * 0.5;
    vec3 rgb;
    if (hit.surface == 3) {
        rgb = object_colors[hit.part - 10].rgb * ((0.55 + 0.45 * hit.brightness) * dim);
    } else {
        rgb = groundColor(hit.point) * (0.6 + 0.4 * hit.brightness);
    }
    gl_FragColor = vec4(rgb, 1.0);
}
