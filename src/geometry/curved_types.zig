const curved_projection = @import("../render/curved_projection.zig");
const curved_ambient = @import("curved_ambient.zig");

pub const Metric = enum { hyperbolic, elliptic, spherical };

pub const ChartModel = enum {
    projective,
    conformal,
};

pub const Params = struct {
    radius: f32 = 1.0,
    angular_zoom: f32,
    chart_model: ChartModel = .projective,
};

pub const CameraModel = curved_projection.CameraModel;
pub const DistanceClip = curved_projection.DistanceClip;
pub const Screen = curved_projection.Screen;

pub const WalkOrientation = struct {
    x_heading: f32,
    z_heading: f32,
    pitch: f32,
};

pub const Sample = curved_projection.Sample;
pub const SampleStatus = curved_projection.SampleStatus;
pub const ProjectedSample = curved_projection.ProjectedSample;

pub const Flat3 = curved_ambient.Flat3;
pub const Vec3 = Flat3.Vector;

pub fn AmbientFor(comptime metric: Metric) type {
    return switch (metric) {
        .hyperbolic => curved_ambient.Hyper,
        .elliptic, .spherical => curved_ambient.Round,
    };
}

pub fn TypedCamera(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        position: Ambient.Vector,
        right: Ambient.Vector,
        up: Ambient.Vector,
        forward: Ambient.Vector,
    };
}

pub fn TypedWalkBasis(comptime metric: Metric) type {
    const Ambient = AmbientFor(metric);
    return struct {
        forward: Ambient.Vector,
        right: Ambient.Vector,
        up: Ambient.Vector,
    };
}
