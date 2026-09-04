#!/usr/bin/env python3
"""Generate a Rojo-compatible sourcemap.json from src/ so luau-lsp can resolve
cross-module requires. Kept in-repo so CI and Claude Code can type-check the
project without installing Rojo."""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")

# src/<dir> -> (roblox service path, className)
MOUNTS = [
    (["ReplicatedStorage"], ["ReplicatedStorage"], "ReplicatedStorage"),
    (["ServerScriptService"], ["ServerScriptService"], "ServerScriptService"),
    (["ServerStorage"], ["ServerStorage"], "ServerStorage"),
    (["StarterPlayer", "StarterPlayerScripts"],
     ["StarterPlayer", "StarterPlayerScripts"], "StarterPlayerScripts"),
]


def script_node(path, name):
    if name.endswith(".server.luau"):
        return {"name": name[: -len(".server.luau")], "className": "Script", "filePaths": [path]}
    if name.endswith(".client.luau"):
        return {"name": name[: -len(".client.luau")], "className": "LocalScript", "filePaths": [path]}
    return {"name": name[: -len(".luau")], "className": "ModuleScript", "filePaths": [path]}


def walk(directory, name, class_name="Folder"):
    node = {"name": name, "className": class_name, "children": []}
    if not os.path.isdir(directory):
        return node
    for entry in sorted(os.listdir(directory)):
        full = os.path.join(directory, entry)
        if os.path.isdir(full):
            node["children"].append(walk(full, entry))
        elif entry.endswith(".luau") and entry != "init.luau":
            node["children"].append(script_node(os.path.relpath(full, ROOT), entry))
    return node


def ensure(children, name, class_name):
    for child in children:
        if child["name"] == name:
            return child
    node = {"name": name, "className": class_name, "children": []}
    children.append(node)
    return node


def main():
    root = {"name": "MixAMonster", "className": "DataModel", "children": []}
    for src_parts, dm_parts, leaf_class in MOUNTS:
        directory = os.path.join(SRC, *src_parts)
        cursor = root
        for depth, part in enumerate(dm_parts):
            is_leaf = depth == len(dm_parts) - 1
            cursor = ensure(cursor["children"], part, leaf_class if is_leaf else part)
        built = walk(directory, dm_parts[-1], leaf_class)
        cursor["children"].extend(built["children"])

    out = os.path.join(ROOT, "sourcemap.json")
    with open(out, "w") as handle:
        json.dump(root, handle, indent=2)
    print(out, file=sys.stderr)


if __name__ == "__main__":
    main()
