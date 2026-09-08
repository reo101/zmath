"""Generate the small Blender GLB fixture used by the spherical mesh path."""

from pathlib import Path

import bpy


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets" / "spherical" / "curved_mesh_fixture.glb"

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)


def material(name, color, metallic=0.0, roughness=0.45):
    result = bpy.data.materials.new(name)
    result.diffuse_color = (*color, 1.0)
    result.use_nodes = True
    bsdf = result.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return result


red = material("signal red", (0.8, 0.08, 0.05), metallic=0.1)
blue = material("deep blue", (0.05, 0.2, 0.8), metallic=0.15)
gold = material("warm gold", (0.95, 0.55, 0.08), metallic=0.5, roughness=0.3)

objects = []

bpy.ops.mesh.primitive_cube_add(location=(0.0, 0.0, -0.25), scale=(0.7, 0.7, 0.35))
base = bpy.context.object
base.name = "base"
base.data.materials.append(red)
objects.append(base)

bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.45, depth=0.75, location=(0.0, 0.0, 0.3))
body = bpy.context.object
body.name = "body"
body.data.materials.append(blue)
objects.append(body)

bpy.ops.mesh.primitive_cone_add(vertices=16, radius1=0.5, radius2=0.0, depth=0.65, location=(0.0, 0.0, 1.0))
top = bpy.context.object
top.name = "cap"
top.data.materials.append(gold)
objects.append(top)

for obj in objects:
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    obj.select_set(False)

bpy.ops.export_scene.gltf(
    filepath=str(OUTPUT),
    export_format="GLB",
    export_materials="EXPORT",
    export_apply=True,
)
print(f"wrote {OUTPUT}")
