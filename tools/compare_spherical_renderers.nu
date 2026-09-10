#!/usr/bin/env nu
# Captures the analytic S3 ray tracer and the Vulkan raster path at identical
# poses. The PNG diff is intentionally retained: a scalar error metric hides
# exactly the flying geometry this check exists to expose.

const width = 960
const height = 640
const display = ':96'

let required = ['Xvfb' 'import' 'magick' 'zig']
let missing = ($required | where {|tool| (which $tool | is-empty) })
if not ($missing | is-empty) {
    error make { msg: $'missing tools: ($missing | str join ", ")' }
}

let build = (do { ^zig build demo-spherical-build shader-playground-build spirv-spherical } | complete)
if $build.exit_code != 0 {
    print ($build.stdout + $build.stderr)
    exit $build.exit_code
}

let raytracer = (ls .zig-cache/o/*/zmath-demo-spherical | sort-by modified | reverse | first | get name)
let vulkan = (ls .zig-cache/o/*/zmath-shader-playground | sort-by modified | reverse | first | get name)
mkdir zig-out/renderer-compare
let xvfb = (job spawn { ^Xvfb $display -screen 0 '1280x720x24' -nolisten tcp })
sleep 2sec

let poses = [
    { name: 'initial', walk: '0', yaw: '0', pitch: '0' }
    { name: 'ring', walk: '5.3', yaw: '0', pitch: '0' }
    { name: 'along', walk: '12.6248', yaw: '1.5708', pitch: '0' }
]

mut failed = false
for pose in $poses {
    let reference = $'zig-out/renderer-compare/($pose.name)-raytrace.png'
    let raster = $'zig-out/renderer-compare/($pose.name)-vulkan.png'
    let diff = $'zig-out/renderer-compare/($pose.name)-diff.png'

    with-env {
        DISPLAY: $display
        WAYLAND_DISPLAY: ''
        XDG_SESSION_TYPE: 'x11'
        ZMATH_DEMO_CAPTURE_ANALYTIC: $reference
        ZMATH_DEMO_WIDTH: ($width | into string)
        ZMATH_DEMO_HEIGHT: ($height | into string)
        ZMATH_DEMO_WALK: $pose.walk
        ZMATH_DEMO_YAW: $pose.yaw
        ZMATH_DEMO_PITCH: $pose.pitch
    } { ^$raytracer }

    let walk = $pose.walk
    let yaw = $pose.yaw
    let pitch = $pose.pitch
    let app = (job spawn { with-env { DISPLAY: $display WAYLAND_DISPLAY: '' XDG_SESSION_TYPE: 'x11' } { ^$vulkan zig-out/shaders/spherical_ground.vert.spv zig-out/shaders/spherical_ground.frag.spv zig-out/shaders/spherical_mesh.vert.spv zig-out/shaders/spherical_mesh.frag.spv --pose $walk $yaw $pitch } })
    sleep 4sec
    let screenshot = (do { with-env { DISPLAY: $display } { ^import -window 'zmath SPIR-V playground' $raster } } | complete)
    try { job kill $app }
    if $screenshot.exit_code != 0 {
        print $'($pose.name): Vulkan capture failed: ($screenshot.stderr | str trim)'
        $failed = true
        continue
    }

    let compare = (do { ^magick compare -metric AE $reference $raster $diff } | complete)
    let metric = ($compare.stdout + $compare.stderr | str trim)
    print $'($pose.name): ($metric) differing RGBA samples, diff: ($diff)'
    if $compare.exit_code > 1 { $failed = true }
}
try { job kill $xvfb }
if $failed { exit 1 }
