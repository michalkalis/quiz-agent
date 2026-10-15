#!/usr/bin/env python3
"""CarPlay isolation guard (#97 — CarPlay support).

CarPlay is built and tested in Local builds only until Apple grants the
entitlement and the founder decides to ship it. Apple shows a CarPlay app to
every user the moment the entitlement is in a shipped build, so the configs
TestFlight and the App Store build from (Staging, Prod) must stay free of it:

  1. No Staging/Prod config compiles the CARPLAY flag.
  2. No Staging/Prod config signs with an entitlements file holding a CarPlay key.
  3. No Info.plist a Staging/Prod config uses declares a CarPlay scene.
  4. Every Swift file that imports CarPlay is wrapped in `#if CARPLAY`.

Rules 1-3 read the resolved build settings from xcodebuild, so they need Xcode.

Usage: scripts/lint-carplay-isolation.py [--root <repo>]   exit 1 on any finding.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SHIPPED_CONFIGS = ["Debug-Staging", "Release-Staging", "Debug-Prod", "Release-Prod"]
SDKS = ["iphoneos", "iphonesimulator"]
CARPLAY_SCENE_ROLE = "CPTemplateApplicationSceneSessionRoleApplication"


def build_settings(project_dir: Path, config: str, sdk: str) -> dict[str, str]:
    out = subprocess.run(
        [
            "xcodebuild",
            "-project",
            "Hangs.xcodeproj",
            "-target",
            "Hangs",
            "-configuration",
            config,
            "-sdk",
            sdk,
            "-showBuildSettings",
            "-json",
        ],
        cwd=project_dir,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return json.loads(out)[0]["buildSettings"]


def check_shipped_configs(project_dir: Path) -> list[str]:
    findings = []
    for config in SHIPPED_CONFIGS:
        for sdk in SDKS:
            where = f"{config} ({sdk})"
            settings = build_settings(project_dir, config, sdk)
            if (
                "CARPLAY"
                in settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
            ):
                findings.append(f"{where}: compiles the CARPLAY flag")
            entitlements = settings.get("CODE_SIGN_ENTITLEMENTS")
            if (
                entitlements
                and "carplay" in (project_dir / entitlements).read_text().lower()
            ):
                findings.append(
                    f"{where}: signs with CarPlay entitlements ({entitlements})"
                )
            plist = settings.get("INFOPLIST_FILE")
            if plist and CARPLAY_SCENE_ROLE in (project_dir / plist).read_text():
                findings.append(f"{where}: {plist} declares a CarPlay scene")
    return findings


def check_sources(app_dir: Path) -> list[str]:
    findings = []
    for path in sorted(app_dir.rglob("*.swift")):
        text = path.read_text()
        if not re.search(r"^\s*import CarPlay\b", text, re.MULTILINE):
            continue
        code = [
            line.strip()
            for line in text.splitlines()
            if line.strip() and not line.strip().startswith("//")
        ]
        if not code or code[0] != "#if CARPLAY":
            findings.append(
                f"{path.relative_to(app_dir.parent)}: imports CarPlay outside `#if CARPLAY`"
            )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parent.parent
    )
    args = parser.parse_args()
    project_dir = args.root / "apps/ios-app/Hangs"

    findings = check_sources(project_dir / "Hangs") + check_shipped_configs(project_dir)
    for finding in findings:
        print(f"CarPlay isolation: {finding}")
    if findings:
        print(
            "CarPlay may ship only after Apple's grant and a founder go (#97, phase 6)."
        )
        return 1
    print(
        f"CarPlay isolation OK: {', '.join(SHIPPED_CONFIGS)} carry no CarPlay flag, entitlement or scene."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
