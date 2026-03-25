const canvas = @import("../render/canvas.zig");
const projection = @import("../render/projection.zig");

pub const Canvas = canvas.Canvas;
pub const MarkerColor = canvas.MarkerColor;

pub const DirectionProjection = projection.DirectionProjection;
pub const ProjectionMode = projection.EuclideanProjection;

pub const directionProjectionLabel = projection.directionProjectionLabel;
pub const projectSimple = projection.projectEuclidean;
pub const projectDirection = projection.projectDirection;
pub const projectStereographicDirection = projection.projectStereographicDirection;
pub const projectOrthographicDirection = projection.projectOrthographicDirection;
pub const projectAngularDirection = projection.projectAngularDirection;
pub const projectWrappedAngularDirection = projection.projectWrappedAngularDirection;
pub const projectDirectionWith = projection.projectDirectionWith;
pub const projectPGA = projection.projectPGA;
