"""Read-only App Store Connect readiness audit: TestFlight beta info + App Store listing.

Companion to asc_audit.py (products/prices). Prints a compact JSON summary of what is
filled in ASC for external TestFlight and App Store submission. GET requests only.
"""

from __future__ import annotations

import json
import sys

from asc_audit import BUNDLE_ID, attrs, get


def short(value, n: int = 70):
    if isinstance(value, str) and len(value) > n:
        return f"{value[:n]}… ({len(value)} chars)"
    return value


def compact(item, drop=()):
    return {k: short(v) for k, v in attrs(item).items() if k not in drop and v not in (None, "", [])}


def main() -> int:
    apps = get("/apps", **{"filter[bundleId]": BUNDLE_ID})
    if "_error" in apps or not apps.get("data"):
        print(json.dumps({"apps": apps}, indent=1))
        return 1
    app = apps["data"][0]
    app_id = app["id"]
    r: dict = {"app": compact(app)}

    # --- TestFlight
    r["betaAppLocalizations"] = [compact(i) for i in get(f"/apps/{app_id}/betaAppLocalizations").get("data", [])]
    detail = get(f"/apps/{app_id}/betaAppReviewDetail")
    r["betaAppReviewDetail"] = compact(detail["data"]) if detail.get("data") else detail
    lic = get(f"/apps/{app_id}/betaLicenseAgreement")
    r["betaLicenseAgreement"] = compact(lic["data"]) if lic.get("data") else lic
    r["betaGroups"] = [compact(g) for g in get(f"/apps/{app_id}/betaGroups", limit=50).get("data", [])]
    r["betaTesters_count"] = len(get("/betaTesters", limit=200, **{"filter[apps]": app_id}).get("data", []))

    builds = get("/builds", limit=5, sort="-uploadedDate", include="buildBetaDetail,preReleaseVersion,betaBuildLocalizations", **{"filter[app]": app_id})
    inc = {(i["type"], i["id"]): i for i in builds.get("included", [])}
    r["builds"] = []
    for b in builds.get("data", []):
        row = {k: v for k, v in attrs(b).items() if k in ("id", "version", "uploadedDate", "processingState", "expired", "usesNonExemptEncryption", "minOsVersion")}
        rel = b.get("relationships", {})
        pre = (rel.get("preReleaseVersion", {}).get("data") or {})
        row["marketingVersion"] = inc.get((pre.get("type"), pre.get("id")), {}).get("attributes", {}).get("version")
        bd = (rel.get("buildBetaDetail", {}).get("data") or {})
        row["betaDetail"] = inc.get((bd.get("type"), bd.get("id")), {}).get("attributes")
        row["whatToTest"] = [
            {"locale": inc[(d["type"], d["id"])]["attributes"].get("locale"), "whatsNew": short(inc[(d["type"], d["id"])]["attributes"].get("whatsNew"))}
            for d in (rel.get("betaBuildLocalizations", {}).get("data") or []) if (d["type"], d["id"]) in inc
        ]
        sub = get("/betaAppReviewSubmissions", **{"filter[build]": b["id"]})
        row["betaReviewSubmission"] = [compact(s) for s in sub.get("data", [])]
        r["builds"].append(row)
    r["encryptionDeclarations"] = [compact(d) for d in get(f"/apps/{app_id}/appEncryptionDeclarations").get("data", [])]

    # --- App Store listing
    infos = get(f"/apps/{app_id}/appInfos", include="appInfoLocalizations,primaryCategory,secondaryCategory")
    r["appInfos"] = []
    for info in infos.get("data", []):
        row = compact(info)
        rel = info.get("relationships", {})
        row["primaryCategory"] = (rel.get("primaryCategory", {}).get("data") or {}).get("id")
        row["secondaryCategory"] = (rel.get("secondaryCategory", {}).get("data") or {}).get("id")
        row["localizations"] = [compact(i) for i in infos.get("included", []) if i["type"] == "appInfoLocalizations"
                                and i["id"] in {d["id"] for d in rel.get("appInfoLocalizations", {}).get("data", [])}]
        age = get(f"/appInfos/{info['id']}/ageRatingDeclaration")
        row["ageRatingDeclaration"] = compact(age["data"]) if age.get("data") else age
        r["appInfos"].append(row)

    eula = get(f"/apps/{app_id}/endUserLicenseAgreement")
    r["customEula"] = bool(eula.get("data"))

    r["appStoreVersions"] = []
    for v in get(f"/apps/{app_id}/appStoreVersions", limit=3).get("data", []):
        row = compact(v)
        locs = []
        for loc in get(f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations").get("data", []):
            lrow = compact(loc)
            sets = get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", include="appScreenshots")
            lrow["screenshotSets"] = {
                s["attributes"]["screenshotDisplayType"]: len(s.get("relationships", {}).get("appScreenshots", {}).get("data", []))
                for s in sets.get("data", [])
            }
            locs.append(lrow)
        row["localizations"] = locs
        rd = get(f"/appStoreVersions/{v['id']}/appStoreReviewDetail")
        row["reviewDetail"] = compact(rd["data"]) if rd.get("data") else rd
        build = get(f"/appStoreVersions/{v['id']}/build")
        row["attachedBuild"] = attrs(build["data"]).get("version") if build.get("data") else None
        r["appStoreVersions"].append(row)

    print("=== ASC READINESS REPORT ===")
    print(json.dumps(r, indent=1, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
