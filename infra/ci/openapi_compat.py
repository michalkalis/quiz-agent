"""API compatibility gate for live iOS builds (#207 task 207.26).

Fails when the working tree's OpenAPI spec (quiz-agent and quiz-pack-api)
breaks a client written against a released iOS build: a removed or renamed
endpoint or response field, a response field that may now be missing, a new
required request field, a new enum value a strict Swift enum cannot decode, and
the rest of oasdiff's ERR-level rules (https://github.com/oasdiff/oasdiff).

Baseline = the newest `ios/<version>-b<build>` (or `ios/<version>-final`) tag
of every marketing version not in RETIRED_VERSIONS: the App Store build and the
TestFlight builds of that version all stand on it, because each PR since has
been checked against it. Specs are built by importing each app at the tag
(`app.openapi()`, no server or DB), so a tag needs only its source tree.

Run from the repo root with the backend deps installed and `oasdiff` on PATH
(CI: backend-ci.yml, job verify-openapi). Tags must be fetched.

An intentional break (the contract step after no live build uses the old
shape) goes into infra/ci/openapi-compat-ignore.txt with a reason, in the same
PR; admin and internal paths are excluded below because no app calls them.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Marketing versions whose builds are no longer installable (TestFlight builds
# expire after 90 days, App Store versions once a newer one is the only one
# sold). Add a version here in the PR that retires it.
RETIRED_VERSIONS: set[str] = set()

# Paths no iOS build calls: admin APIs, the review web UI, ops pings.
APPS = {
    "quiz-agent": r"^/api/v1/admin/",
    "quiz-pack-api": r"^/(api/|web/|v1/admin/|v1/worker/)",
}

TAG_RE = re.compile(
    r"^ios/(?P<version>\d+(?:\.\d+)*)-(?:b(?P<build>\d+)|(?P<final>final))$"
)
ROOT = Path(__file__).resolve().parents[2]
IGNORE_FILE = ROOT / "infra/ci/openapi-compat-ignore.txt"
# Pydantic fields with a default are "optional" in the spec, so oasdiff rates
# their removal info-level; a Swift Codable struct without that key still fails
# to decode, so for us it is an error.
SEVERITY_FILE = ROOT / "infra/ci/openapi-compat-severity.txt"


def baseline_tags() -> list[str]:
    tags = subprocess.run(
        ["git", "tag", "-l", "ios/*"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    newest: dict[str, tuple[float, str]] = {}
    for tag in tags:
        m = TAG_RE.match(tag)
        if not m:
            print(
                f"::notice::skipping tag {tag} (not ios/<version>-b<build> or -final)"
            )
            continue
        version = m["version"]
        rank = float("inf") if m["final"] else int(m["build"])
        if version not in RETIRED_VERSIONS and rank > newest.get(version, (-1, ""))[0]:
            newest[version] = (rank, tag)
    return [tag for _, tag in sorted(newest.values(), key=lambda v: v[1])]


def extract(tag: str, dest: Path) -> Path:
    archive = subprocess.run(
        [
            "git",
            "archive",
            "--format=tar",
            tag,
            "apps/quiz-agent",
            "apps/quiz-pack-api",
            "packages/shared",
            "data/examples",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout
    tar_path = dest.parent / f"{dest.name}.tar"
    tar_path.write_bytes(archive)
    with tarfile.open(tar_path) as tar:
        tar.extractall(dest, filter="data")
    return dest


def build_spec(src: Path, app: str, out: Path) -> None:
    app_dir = src / "apps" / app
    env = {
        **os.environ,
        "PYTHONPATH": f"{app_dir}{os.pathsep}{src / 'packages/shared'}",
        # Import-time SDK clients want a key; the spec never calls them.
        "OPENAI_API_KEY": os.environ.get("OPENAI_API_KEY")
        or "sk-openapi-compat-placeholder",
    }
    # Written to a file, not stdout: app logging may print on import.
    code = "import json, sys; from app.main import app; json.dump(app.openapi(), open(sys.argv[1], 'w'))"
    result = subprocess.run(
        [sys.executable, "-c", code, str(out)],
        cwd=app_dir,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(
            f"::error::could not build the {app} OpenAPI spec from {src}:\n{result.stderr[-2000:]}"
        )


def main() -> int:
    tags = baseline_tags()
    if not tags:
        print("::error::no ios/* baseline tag found (fetch tags before running)")
        return 1
    print(f"baselines: {', '.join(tags)}")
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        head = {app: work / f"head-{app}.json" for app in APPS}
        for app in APPS:
            build_spec(ROOT, app, head[app])
        for tag in tags:
            src = extract(tag, work / tag.replace("/", "_"))
            for app, unmatch in APPS.items():
                base = work / f"{tag.replace('/', '_')}-{app}.json"
                build_spec(src, app, base)
                result = subprocess.run(
                    [
                        "oasdiff",
                        "breaking",
                        str(base),
                        str(head[app]),
                        "--fail-on",
                        "ERR",
                        "--unmatch-path",
                        unmatch,
                        "--err-ignore",
                        str(IGNORE_FILE),
                        "--severity-levels",
                        str(SEVERITY_FILE),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if result.returncode == 0:
                    print(f"ok    {app} vs {tag}")
                    continue
                failed = True
                what = "breaks" if "error\t[" in result.stdout else "oasdiff failed on"
                print(f"::error::{app} {what} the iOS build {tag}")
                print(result.stdout + result.stderr)
    if failed:
        print(
            "Live iOS builds would break. Keep the old field/endpoint (expand now, contract "
            "after no live build uses it), or, if it is truly unused, list it in "
            "infra/ci/openapi-compat-ignore.txt with a reason."
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
