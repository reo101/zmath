const curved_charts = @import("curved_charts.zig");
const curved_sampling = @import("curved_sampling.zig");
const curved_surface = @import("curved_surface.zig");
const curved_types = @import("curved_types.zig");
const curved_view = @import("curved_view.zig");
const curved_projection = @import("../render/curved_projection.zig");

pub const Metric = curved_types.Metric;
pub const ChartModel = curved_types.ChartModel;
pub const Params = curved_types.Params;
pub const CameraModel = curved_types.CameraModel;
pub const DistanceClip = curved_types.DistanceClip;
pub const Screen = curved_types.Screen;
pub const WalkOrientation = curved_types.WalkOrientation;
pub const Sample = curved_types.Sample;
pub const SampleStatus = curved_types.SampleStatus;
pub const ProjectedSample = curved_types.ProjectedSample;

pub const CameraError = curved_view.CameraError;

pub const Vec3 = curved_types.Vec3;
pub const AmbientFor = curved_types.AmbientFor;
pub const TypedCamera = curved_types.TypedCamera;
pub const TypedWalkBasis = curved_types.TypedWalkBasis;

pub const vec3 = curved_charts.vec3;
pub const vec3x = curved_charts.vec3x;
pub const vec3y = curved_charts.vec3y;
pub const vec3z = curved_charts.vec3z;
pub const vec3Coords = curved_charts.vec3Coords;
pub const flatLerp3 = curved_charts.flatLerp3;
pub const flatBilerpQuad = curved_charts.flatBilerpQuad;
pub const chartCoordsTyped = curved_charts.chartCoords;
pub const sphericalAmbientFromLocalPoint = curved_charts.sphericalAmbientFromLocalPoint;
pub const sphericalAmbientFromGroundHeightPoint = curved_surface.sphericalAmbientFromGroundHeightPoint;
pub const ambientFromTypedTangentBasisPoint = curved_surface.ambientFromTypedTangentBasisPoint;

pub const projectSample = curved_projection.projectSample;
pub const shouldBreakProjectedSegment = curved_projection.shouldBreakProjectedSegment;

pub const sampleProjectedModelPoint = curved_sampling.sampleProjectedModelPoint;
pub const modelPointForTypedAmbientWithCamera = curved_sampling.modelPointForTypedAmbientWithCamera;

pub const TypedView = curved_view.TypedView;
pub const HyperView = curved_view.HyperView;
pub const EllipticView = curved_view.EllipticView;
pub const SphericalView = curved_view.SphericalView;
pub const SphericalRenderPass = curved_view.SphericalRenderPass;
