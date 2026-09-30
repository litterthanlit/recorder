#!/usr/bin/env python3
"""Registers new Swift files in Recorder.xcodeproj (which is edited by hand).

    scripts/pbxproj-add.py <group path> <File.swift> [<File.swift> ...]
    scripts/pbxproj-add.py --remove <File.swift> [...]

<group path> is relative to the Recorder folder, e.g. `Timeline` or `UI/Capture`. Missing
groups are created under their parent. Each file gets a PBXFileReference (next free A2… ID),
a PBXBuildFile (next free B2… ID), a child entry in its group and an entry in the Sources
build phase. Files already registered are skipped. `--remove` deletes all four entries.
"""

import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "Recorder.xcodeproj" / "project.pbxproj"
SOURCES_PHASE = "D20000000000000000000003"
ROOT_SOURCE_GROUP = "C20000000000000000000002"  # the `Recorder` group


def next_id(text: str, prefix: str) -> str:
    used = [int(m, 16) for m in re.findall(prefix + r"([0-9A-F]{22})", text)]
    return prefix + format(max(used) + 1, "022X")


def insert_before_section_end(text: str, section: str, line: str) -> str:
    marker = f"/* End {section} section */"
    return text.replace(marker, f"{line}\n{marker}", 1)


def group_block(text: str, group_id: str) -> re.Match:
    match = re.search(
        rf"\t\t{group_id} /\* [^*]+ \*/ = \{{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n(.*?)\t\t\t\);",
        text,
        re.S,
    )
    if not match:
        raise SystemExit(f"group {group_id} not found")
    return match


def add_child(text: str, group_id: str, child_id: str, name: str) -> str:
    block = group_block(text, group_id)
    insert_at = block.end(1)
    return text[:insert_at] + f"\t\t\t\t{child_id} /* {name} */,\n" + text[insert_at:]


def find_group(text: str, parent_id: str, name: str):
    children = group_block(text, parent_id).group(1)
    for child_id, child_name in re.findall(r"(C2[0-9A-F]{22}) /\* ([^*]+) \*/", children):
        if child_name == name:
            return child_id
    return None


def ensure_group(text: str, path: str):
    parent = ROOT_SOURCE_GROUP
    for component in path.split("/"):
        existing = find_group(text, parent, component)
        if existing:
            parent = existing
            continue
        group_id = next_id(text, "C2")
        block = (
            f"\t\t{group_id} /* {component} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"\t\t\t);\n"
            f"\t\t\tpath = {component};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )
        text = insert_before_section_end(text, "PBXGroup", block)
        text = add_child(text, parent, group_id, component)
        parent = group_id
    return text, parent


def quoted(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z0-9_.]+", name) else f'"{name}"'


def add_files(text: str, group_path: str, names):
    text, group_id = ensure_group(text, group_path)
    for name in names:
        if f"/* {name} */ = {{isa = PBXFileReference" in text:
            print(f"skip {name}: already registered")
            continue
        file_id = next_id(text, "A2")
        text = insert_before_section_end(
            text,
            "PBXFileReference",
            f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {quoted(name)}; sourceTree = \"<group>\"; }};",
        )
        build_id = next_id(text, "B2")
        text = insert_before_section_end(
            text,
            "PBXBuildFile",
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};",
        )
        text = add_child(text, group_id, file_id, name)
        text = text.replace(
            f"\t\t{SOURCES_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n",
            f"\t\t{SOURCES_PHASE} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n"
            f"\t\t\t\t{build_id} /* {name} in Sources */,\n",
            1,
        )
        print(f"added {group_path}/{name}: {file_id} {build_id}")
    return text


def remove_files(text: str, names):
    for name in names:
        match = re.search(rf"(A2[0-9A-F]{{22}}) /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference", text)
        if not match:
            print(f"skip {name}: not registered")
            continue
        file_id = match.group(1)
        build = re.search(rf"(B2[0-9A-F]{{22}}) /\* {re.escape(name)} in Sources \*/ = \{{", text)
        lines = text.split("\n")
        drop = [file_id] + ([build.group(1)] if build else [])
        lines = [line for line in lines if not any(line.strip().startswith(i) for i in drop)]
        text = "\n".join(lines)
        print(f"removed {name}")
    return text


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    text = PROJECT.read_text()
    if args[0] == "--remove":
        text = remove_files(text, args[1:])
    else:
        if len(args) < 2:
            raise SystemExit(__doc__)
        text = add_files(text, args[0].strip("/"), args[1:])
    PROJECT.write_text(text)


if __name__ == "__main__":
    main()
