#!/usr/bin/env python3
"""Check the real SwiftPM dependency graph and Xcode's use of the same app product."""

import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run_json(*command):
    return json.loads(subprocess.check_output(command, cwd=ROOT))


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    package = run_json("swift", "package", "describe", "--type", "json")
    targets = {target["name"]: target for target in package["targets"]}
    native = {
        "UntitledPluginCapture": "screenshot",
        "UntitledPluginSharing": "peripheral-sharing",
        "UntitledPluginSpeech": "doubao-speech-input",
    }
    interface = {"UntitledPluginSDK", "UntitledHost"}
    expected = {
        "UntitledPluginSDK": set(),
        "UntitledHost": {"UntitledPluginSDK"},
        **{module: interface for module in native},
        "UntitledComposition": interface | native.keys(),
        "Untitled": {"UntitledComposition"},
        "DictationIMEKit": set(),
        "UntitledDictationInputMethod": {"DictationIMEKit"},
    }
    for module, dependencies in expected.items():
        require(set(targets[module].get("target_dependencies", [])) == dependencies,
                f"Unexpected compile-time dependency in {module}")
    for module, slug in native.items():
        path = ROOT / "Plugins" / slug / "Sources"
        require(ROOT / targets[module]["path"] == path, f"Wrong source path for {module}")
        actual = {p.relative_to(path).as_posix() for p in path.rglob("*.swift")}
        require(actual == set(targets[module]["sources"]), f"Unassigned or missing source in {module}")
    for name in ("DictationMarkedTextTarget.swift", "DictationMarkedTextBridge.swift", "DictationInputMethodCheck.swift"):
        require("IMEValidation/" + name in targets["UntitledTests"]["sources"], f"Missing IME regression fixture: {name}")

    product = next(p for p in package["products"] if p["name"] == "UntitledComposition")
    require(product["type"] == {"library": ["static"]} and product["targets"] == ["UntitledComposition"],
            "Xcode's composition product must be statically linked")
    project = run_json("plutil", "-convert", "json", "-o", "-", "Untitled.xcodeproj/project.pbxproj")
    objects = project["objects"]
    root = objects[project["rootObject"]]
    app = next(objects[ref] for ref in root["targets"] if objects[ref]["name"] == "Untitled")
    phases = {objects[ref]["isa"]: objects[ref] for ref in app["buildPhases"]}
    sources = phases["PBXSourcesBuildPhase"]["files"]
    require(len(sources) == 1, "Xcode must not compile the host or plugins as part of the app target")
    entry = objects[objects[sources[0]]["fileRef"]]
    require(entry["sourceTree"] == "SOURCE_ROOT" and entry["path"] == "Sources/UntitledEntry/UntitledEntry.swift",
            "Xcode and SwiftPM must use the same app entry")
    deps = app.get("packageProductDependencies", [])
    require(len(deps) == 1, "Xcode must link the same composition product")
    dep = objects[deps[0]]
    require(dep["productName"] == product["name"] and dep["package"] in root.get("packageReferences", []),
            "Xcode is not linked to the local composition product")
    local_package = objects[dep["package"]]
    require(local_package["isa"] == "XCLocalSwiftPackageReference" and local_package["relativePath"] == ".",
            "Xcode must resolve the package in this checkout")
    linked = [objects[f].get("productRef") for f in phases["PBXFrameworksBuildPhase"]["files"]]
    require(linked == deps, "Xcode must link the composition product in its Frameworks phase")
    hook = "scripts/stage-plugin-resources.sh"
    require(hook in phases["PBXShellScriptBuildPhase"]["shellScript"] and hook in (ROOT / "scripts/build-app.sh").read_text(),
            "The Xcode and command-line builds must stage the same plugin resources")
    print("SwiftPM dependencies, test-only IME, and Xcode static composition verified.")


if __name__ == "__main__":
    main()
