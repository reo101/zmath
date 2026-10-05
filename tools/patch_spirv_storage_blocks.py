"""Repair SPIR-V interface decorations emitted by Zig."""

import re
import sys
from pathlib import Path


source = Path(sys.argv[1]).read_text()
lines = source.splitlines()


def convert_sequence(value, result, target_type, component_type):
    components = [f"{result}_component_{index}" for index in range(4)]
    return [
        f"{component} = OpCompositeExtract {component_type} {value} {index}"
        for index, component in enumerate(components)
    ] + [f"{result} = OpCompositeConstruct {target_type} {' '.join(components)}"]


def convert_carrier(value, result, source_member, target_member, target_struct, component_type):
    member = f"{result}_member"
    converted = f"{result}_converted_member"
    return [f"{member} = OpCompositeExtract {source_member} {value} 0"] + convert_sequence(
        member, converted, target_member, component_type
    ) + [f"{result} = OpCompositeConstruct {target_struct} {converted}"]


# Position requires a float4 member, even when the local carrier stores an array.
# Keep interface blocks distinct from carriers used in Function storage.
pointer_types = dict(re.findall(r"(%\S+)\s*=\s*OpTypePointer (?:Input|Output) (%\S+)", source))
variable_types = dict(re.findall(r"(%\S+)\s*=\s*OpVariable (%\S+) (?:Input|Output)", source))
single_member_structs = dict(re.findall(r"^\s*(%\S+)\s*=\s*OpTypeStruct (%\S+)\s*$", source, re.MULTILINE))
vector_types = {vector: (component, int(count)) for vector, component, count in re.findall(
    r"(%\S+)\s*=\s*OpTypeVector (%\S+) (\d+)", source
)}
array_types = dict((array, (component, length)) for array, component, length in re.findall(
    r"(%\S+)\s*=\s*OpTypeArray (%\S+) (%\S+)", source
))
constants = dict(re.findall(r"(%\S+)\s*=\s*OpConstant %\S+ (\d+)\s*$", source, re.MULTILINE))
float32_types = set(re.findall(r"(%\S+)\s*=\s*OpTypeFloat 32\b", source))
vector_for_component = {component: vector for vector, (component, count) in vector_types.items() if count == 4}
pointers = {(storage, pointee): pointer for pointer, storage, pointee in re.findall(
    r"(%\S+)\s*=\s*OpTypePointer (Input|Output) (%\S+)", source
)}
declarations = []
interfaces = {}
for index, line in enumerate(lines):
    if match := re.search(r"OpDecorate (%\S+) BuiltIn Position", line):
        variable = match.group(1)
        struct_id = pointer_types.get(variable_types.get(variable))
        member = single_member_structs.get(struct_id)
        if member in vector_types:
            component, count = vector_types[member]
            vector = member
        elif member in array_types:
            component, length = array_types[member]
            count = int(constants.get(length, 0))
            if component not in float32_types or count != 4:
                continue
            if component not in vector_for_component:
                vector_for_component[component] = f"{variable}_interface_vector"
                declarations.append(f"{vector_for_component[component]} = OpTypeVector {component} 4")
            vector = vector_for_component[component]
        else:
            continue
        if component not in float32_types or count != 4:
            continue
        block = f"{variable}_interface_type"
        interfaces[variable] = (struct_id, block, member, vector, component)
        declarations.append(f"{block} = OpTypeStruct {vector}")
        lines[index] = f"OpMemberDecorate {block} 0 BuiltIn Position\nOpDecorate {block} Block"


def interface_pointer(storage, pointee, identifier):
    if (storage, pointee) not in pointers:
        pointers[storage, pointee] = identifier
        declarations.append(f"{identifier} = OpTypePointer {storage} {pointee}")
    return pointers[storage, pointee]


# ponytail: direct loads/stores and member access only; escaping interface pointers
# need compiler support and are rejected by the build's spirv-val check.
variables = []
# Retype Position member chains, including Zig's array-typed element pointers.
member_pointers = {}
interface_storage = {}
for index, line in enumerate(lines):
    if match := re.search(r"(%\S+)\s*=\s*OpVariable (%\S+) (Input|Output)", line):
        variable, pointer_type, storage = match.groups()
        if variable in interfaces:
            _, block, _, _, _ = interfaces[variable]
            pointer = interface_pointer(storage, block, f"{variable}_interface_pointer")
            interface_storage[variable] = storage
            variables.append(line.replace(pointer_type, pointer))
            lines[index] = ""
    elif match := re.search(r"(%\S+)\s*=\s*(Op(?:InBounds)?AccessChain) (%\S+) (%\S+) (.*)", line):
        result, opcode, pointer_type, base, indices = match.groups()
        indices = indices.split()
        if base in interfaces and len(indices) in (1, 2):
            interface = interfaces[base]
            storage = interface_storage[base]
            pointee = interface[3] if len(indices) == 1 else interface[4]
            if len(indices) == 1:
                member_pointers[result] = (interface, storage)
        elif base in member_pointers and len(indices) == 1:
            interface, storage = member_pointers[base]
            pointee = interface[4]
        else:
            continue
        pointer = interface_pointer(storage, pointee, f"{result}_interface_pointer")
        lines[index] = f"{result} = {opcode} {pointer} {base} {' '.join(indices)}"
    elif match := re.search(r"OpStore (%\S+) (%\S+)(.*)", line):
        variable, value, operands = match.groups()
        converted = f"{variable}_interface_value_{index}"
        if variable in interfaces:
            _, block, member, vector, component = interfaces[variable]
            if member == vector:
                conversion = [f"{converted} = OpCopyLogical {block} {value}"]
            else:
                conversion = convert_carrier(value, converted, member, vector, block, component)
        elif variable in member_pointers:
            (_, _, member, vector, component), _ = member_pointers[variable]
            if member == vector:
                continue
            conversion = convert_sequence(value, converted, vector, component)
        else:
            continue
        lines[index] = "\n".join(conversion + [f"OpStore {variable} {converted}{operands}"])
    elif match := re.search(r"(%\S+)\s*=\s*OpLoad (%\S+) (%\S+)(.*)", line):
        result, result_type, variable, operands = match.groups()
        loaded = f"{variable}_interface_value_{index}"
        if variable in interfaces:
            _, block, member, vector, component = interfaces[variable]
            if member == vector:
                conversion = [f"{result} = OpCopyLogical {result_type} {loaded}"]
            else:
                conversion = convert_carrier(loaded, result, vector, member, result_type, component)
            load_type = block
        elif variable in member_pointers:
            (_, _, member, vector, component), _ = member_pointers[variable]
            if member == vector:
                continue
            load_type = vector
            conversion = convert_sequence(loaded, result, result_type, component)
        else:
            continue
        lines[index] = "\n".join([f"{loaded} = OpLoad {load_type} {variable}{operands}"] + conversion)

if interfaces:
    insert_at = next(index for index, line in enumerate(lines) if re.search(r"=\s*OpFunction\s", line))
    lines[insert_at:insert_at] = declarations + variables

flat_source = " ".join(lines)
if any("BuiltIn FragDepth" in line for line in lines) and not any("DepthReplacing" in line for line in lines):
    if (entry := re.search(r"OpEntryPoint Fragment (%\S+)", flat_source)):
        insert_at = next((i for i, line in enumerate(lines) if "OpExecutionMode" in line), 0) + 1
        lines.insert(insert_at, f"OpExecutionMode {entry.group(1)} DepthReplacing")

Path(sys.argv[3]).write_text("\n".join(lines) + "\n")
