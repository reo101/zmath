#!/usr/bin/env nu
# Golden-image palette check for the spherical demo.
#
# Captures three canonical poses headlessly (Xvfb), classifies the rendered
# pixels against the known face/picket palette, and compares the resulting
# color shares against the committed reference bands. Rendered geometry is
# deterministic, so a share drifting outside its band means the tracer,
# framing, or shading changed without a matching, deliberate re-pin.
#
# Run from the dev shell:  nu tools/golden_check.nu
# Needs: zig, raylib (via flake env), Xvfb, ImageMagick.
# Re-pin after an intentional visual change by copying the printed shares
# into the `reference` table below.

cd ($env.PWD)

const reference = {
    # Default pose: the canonical showcase. Sky cube owns the zenith, the
    # fence's far side hides inside the cube's conjugate region.
    showcase: {
        left_cyan: [17.0, 20.8]
        right_coral: [18.5, 22.0]
        top_amber: [8.0, 11.0]
        front_green: [17.0, 20.8]
        back_violet: [10.5, 13.5]
        picket: [0.0, 0.5]
    }
    # Past the cube (walk 5.3): the wrapped back face dominates; pickets are
    # present but a few pixels tall, so their share must stay negligible.
    ring: {
        left_cyan: [0.0, 0.5]
        right_coral: [0.0, 0.5]
        top_amber: [0.0, 0.5]
        front_green: [0.0, 0.5]
        back_violet: [35.0, 40.0]
        picket: [0.0, 0.5]
    }
    # At the ring crossing, looking along the fence: the picket row is the
    # frame's second-largest surface.
    along: {
        left_cyan: [0.0, 0.5]
        right_coral: [0.0, 0.5]
        top_amber: [0.0, 0.5]
        front_green: [0.0, 0.5]
        back_violet: [3.5, 6.0]
        picket: [11.5, 15.0]
    }
}

const palette = {
    left_cyan: [82 190 224]
    right_coral: [245 96 83]
    top_amber: [255 184 77]
    front_green: [92 173 126]
    back_violet: [143 124 230]
    picket: [226 218 194]
}

def classify [hist: string] {
    let clusters = ($hist | lines | each {|line|
        let m = ($line | parse -r '\s*(?P<count>\d+):\s*\(\s*(?P<r>[\d.]+),(?P<g>[\d.]+),(?P<b>[\d.]+)')
        if ($m | is-empty) { null } else {
            $m | first
            | update count { into int } | update r { into float } | update g { into float } | update b { into float }
        }
    } | compact)
    let total = ($clusters | get count | math sum)
    let rows = ($palette | columns | each {|name|
        let base = ($palette | get $name)
        let bsum = ($base | math sum)
        let matched = ($clusters | each {|c|
            let rgb = [($c.r | math round) ($c.g | math round) ($c.b | math round)]
            let scale = (($rgb | math sum) / $bsum)
            let diffs = (0..2 | each {|i| (($rgb | get $i) - (($base | get $i) * $scale)) | math abs })
            let within = (($scale > 0.55) and ($scale < 1.10) and (($diffs | math max) < 18))
            if $within { $c.count } else { 0 }
        } | math sum)
        {class: $name, share: (100.0 * $matched / $total)}
    })
    {total: $total, classes: $rows}
}

def main [
    --keep-captures  # leave the captured PNGs in zig-out for inspection
] {
    let missing = (['magick', 'Xvfb', 'zig'] | where {|tool| (which $tool | is-empty) })
    if not ($missing | is-empty) {
        print $'ERROR: missing tools: ($missing | str join ", "). Run inside the dev shell (nix develop).'
        exit 1
    }

    print 'building demo...'
    let build = (do { zig build demo-spherical-build } | complete)
    if $build.exit_code != 0 {
        print 'ERROR: demo build failed:'
        print ($build.stderr | lines | last 6 | str join (char nl))
        exit 1
    }
    let exe = (ls .zig-cache/o/*/zmath-demo-spherical | sort-by modified | reverse | first | get name)

    let display = ':97'
    let xvfb = (job spawn { Xvfb $display -screen 0 '1280x720x24' -nolisten tcp })
    sleep 1.5sec

    let poses = [
        {tag: showcase, walk: '', yaw: ''}
        {tag: ring, walk: '5.3', yaw: ''}
        {tag: along, walk: '12.6248', yaw: '1.5708'}
    ]

    mut failures = []
    for pose in $poses {
        let png = $'zig-out/golden-($pose.tag).png'
        mut extra = {}
        if not ($pose.walk | is-empty) { $extra = ($extra | merge { ZMATH_DEMO_WALK: $pose.walk }) }
        if not ($pose.yaw | is-empty) { $extra = ($extra | merge { ZMATH_DEMO_YAW: $pose.yaw }) }
        let pose_env = ({
            DISPLAY: $display
            WAYLAND_DISPLAY: ''
            XDG_SESSION_TYPE: 'x11'
            ZMATH_DEMO_CAPTURE: $png
        } | merge $extra)
        with-env $pose_env { ^$exe }
        if not ($png | path exists) {
            $failures = ($failures | append $'($pose.tag): capture did not produce ($png)')
            continue
        }
        let hist = (magick $png '-colors' '64' '-format' '%c' 'histogram:info:-' | complete | get stdout)
        let fp = (classify $hist)
        let total = ($fp | get total)
        print $'--- ($pose.tag), total pixels ($total)'
        let bands = ($reference | get $pose.tag)
        for row in $fp.classes {
            let band = ($bands | get $row.class)
            let ok = ($row.share >= ($band | first)) and ($row.share <= ($band | last))
            if not $ok {
                $failures = ($failures | append $'($pose.tag)/($row.class): share ($row.share | math round --precision 2)% outside band [($band | str join ", ")]')
            }
            let verdict = (if $ok { 'ok' } else { 'FAIL' })
            print $'  ($row.class): ($row.share | math round --precision 2)%, band [($band | str join ", ")], ($verdict)'
        }
        if not $keep_captures { rm $png }
    }

    try { job kill $xvfb }

    if ($failures | is-empty) {
        print 'golden check: PASS'
    } else {
        print 'golden check: FAIL'
        $failures | each {|f| print $'  ($f)' }
        exit 1
    }
}
