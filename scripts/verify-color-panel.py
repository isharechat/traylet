#!/usr/bin/env python3
"""Run a synthetic native color-panel interaction without launching production services."""
from pathlib import Path
import subprocess
import shutil

ROOT = Path(__file__).resolve().parent.parent
SDK = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"


def main():
    subprocess.run([str(ROOT / "scripts/swift-local.sh"), "build"], cwd=ROOT, check=True)
    sources = sorted(str(p) for p in (ROOT / "Sources/TrayletApp").rglob("*.swift") if p.name != "V2TrayletMain.swift")
    products = ROOT / ".build/out/Products/Debug"
    accessor = ROOT / ".build/out/Intermediates.noindex/Traylet.build/Debug/Traylet-p.build/DerivedSources/resource_bundle_accessor.swift"
    sources.append(str(accessor))
    executable = ROOT / "build/verify-color-panel"
    executable.parent.mkdir(exist_ok=True)
    shutil.copytree(products / "Traylet_TrayletApp.bundle", executable.parent / "Traylet_TrayletApp.bundle", dirs_exist_ok=True)
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library", "-sdk", SDK,
        "-module-cache-path", str(ROOT / ".build/cache/clang"),
        "-I", str(products), str(products / "TrayletCore.o"), *sources,
        str(ROOT / "scripts/verify-color-panel.swift"), "-o", str(executable),
    ], cwd=ROOT, check=True)
    result = subprocess.run([str(executable), str(ROOT / "build/color-panel-evidence")], cwd=ROOT, timeout=30, capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="")
    # AppKit can terminate during event tracking: exit zero alone is not proof of completion.
    if result.returncode == 0 and "COLOR_PANEL_INTERACTION_PASS" not in result.stdout.splitlines():
        raise SystemExit("Native interaction ended without its completion marker")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
