"""Add Block decorations omitted by the Zig 0.16 SPIR-V backend."""

import re
import sys
from pathlib import Path


source = Path(sys.argv[1]).read_text()
lines = source.splitlines()
existing = set(re.findall(r"OpDecorate (%\S+) Block", source))
function_types = set(re.findall(r"%\S+\s*=\s*OpTypePointer Function (%\S+)", source))
lines = [
    line
    for line in lines
    if not (
        (member := re.search(r"OpMemberDecorate (%\S+) \d+ Offset", line))
        and member.group(1) in function_types
    )
    and not (
        (decoration := re.search(r"OpDecorate (%\S+) ArrayStride", line))
        and decoration.group(1) in function_types
    )
]
missing = []
flat_source = " ".join(lines)
if any("BuiltIn FragDepth" in line for line in lines) and not any("DepthReplacing" in line for line in lines):
    if (entry := re.search(r"OpEntryPoint Fragment (%\S+)", flat_source)):
        insert_at = next((i for i, line in enumerate(lines) if "OpExecutionMode" in line), 0) + 1
        lines.insert(insert_at, f"OpExecutionMode {entry.group(1)} DepthReplacing")
flat_source = " ".join(lines)
for match in re.finditer(r"%\S+\s*=\s*OpVariable\s+%(_ptr_StorageBuffer_\S+)\s+StorageBuffer", flat_source):
    struct_id = "%" + match.group(1).split("StorageBuffer_", 1)[1]
    if struct_id not in existing:
        missing.append(f"OpDecorate {struct_id} Block")
        existing.add(struct_id)

if missing:
    insert_at = next((i for i, line in enumerate(lines) if "OpType" in line), len(lines))
    lines[insert_at:insert_at] = missing

Path(sys.argv[3]).write_text("\n".join(lines) + "\n")
