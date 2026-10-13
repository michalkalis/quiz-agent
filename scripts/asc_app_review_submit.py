"""Submit the editable App Store version to App Review, with its in-app purchases.

Steps (dry run unless --apply):
  1. upload missing IAP review screenshots from apps/ios-app/Hangs/fastlane/iap_review/<productId>.png
  2. attach build --build to the editable version (ASC takes the app icon from the attached build)
  3. create (or reuse) a review submission holding the version
  4. submit the products listed in store_copy.json (first IAPs must ride along with a version;
     products not listed there, e.g. the annual plan, stay unsubmitted, founder 2026-10-07)
  5. send the review submission

  python scripts/asc_app_review_submit.py --build 75 [--apply]
Runs in CI with the ASC_API_* secrets (see .github/workflows/asc-store-upload.yml, step "app-review").
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys

import asc_store_upload as up
import requests
from asc_audit import BASE, BUNDLE_ID, get

V2 = BASE.replace("/v1", "/v2")
SHOTS = up.FL / "iap_review"


def upload_review_screenshot(iap: dict) -> None:
    pid = iap["attributes"]["productId"]
    cur = get(f"{V2}/inAppPurchases/{iap['id']}/appStoreReviewScreenshot")
    if cur.get("data") and cur["data"]["attributes"].get("assetDeliveryState", {}).get("state") == "COMPLETE":
        return
    f = SHOTS / f"{pid}.png"
    if not f.exists():
        raise SystemExit(f"  !! {pid}: no review screenshot in ASC and none at {f}")
    data = f.read_bytes()
    res = up.send("POST", "/inAppPurchaseAppStoreReviewScreenshots", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots", "attributes": {"fileName": f.name, "fileSize": len(data)},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap["id"]}}}}})
    if not up.APPLY:
        return
    for op in res["data"]["attributes"]["uploadOperations"]:
        hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        requests.request(op["method"], op["url"], headers=hdrs, data=data[op["offset"]: op["offset"] + op["length"]], timeout=120).raise_for_status()
    sid = res["data"]["id"]
    up.send("PATCH", f"/inAppPurchaseAppStoreReviewScreenshots/{sid}", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots", "id": sid,
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True, help="build number to ship")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    up.APPLY = args.apply
    print("APPLY" if up.APPLY else "DRY RUN (pass --apply to write)")
    app_id = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]
    wanted = set(json.loads((up.FL / "store_copy.json").read_text())["in_app_purchases"]) - {"subscription_group"}

    print("iap review screenshots")
    iaps = [p for p in get(f"/apps/{app_id}/inAppPurchasesV2", limit=50)["data"] if p["attributes"]["productId"] in wanted]
    for p in iaps:
        print(f"  {p['attributes']['productId']}: {p['attributes']['state']}")
        upload_review_screenshot(p)
    subs = [s for g in get(f"/apps/{app_id}/subscriptionGroups", limit=20)["data"]
            for s in get(f"/subscriptionGroups/{g['id']}/subscriptions", limit=20)["data"] if s["attributes"]["productId"] in wanted]

    print("build")
    ver = up.editable_version(app_id)
    builds = get("/builds", **{"filter[app]": app_id, "filter[version]": args.build, "filter[preReleaseVersion.version]": ver["attributes"]["versionString"]})["data"]
    if not builds or builds[0]["attributes"]["processingState"] != "VALID":
        raise SystemExit(f"  !! build {args.build} of {ver['attributes']['versionString']} not found or not processed")
    up.send("PATCH", f"/appStoreVersions/{ver['id']}/relationships/build", {"data": {"type": "builds", "id": builds[0]["id"]}})

    print("review submission")
    open_subs = get("/reviewSubmissions", **{"filter[app]": app_id, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})["data"]
    if open_subs:
        rs_id = open_subs[0]["id"]
    else:
        rs_id = up.send("POST", "/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                                                                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}).get("data", {}).get("id", "<new>")
    items = get(f"/reviewSubmissions/{rs_id}/items")["data"] if open_subs else []
    if not items:
        up.send("POST", "/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rs_id}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}})

    print("in-app purchases")
    for p in iaps:
        if p["attributes"]["state"] in ("READY_TO_SUBMIT", "MISSING_METADATA"):
            up.send("POST", "/inAppPurchaseSubmissions", {"data": {"type": "inAppPurchaseSubmissions",
                    "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": p["id"]}}}}})
    for s in subs:
        print(f"  {s['attributes']['productId']}: {s['attributes']['state']}")
        if s["attributes"]["state"] == "READY_TO_SUBMIT":
            up.send("POST", "/subscriptionSubmissions", {"data": {"type": "subscriptionSubmissions",
                    "relationships": {"subscription": {"data": {"type": "subscriptions", "id": s["id"]}}}}})

    print("submit")
    up.send("PATCH", f"/reviewSubmissions/{rs_id}", {"data": {"type": "reviewSubmissions", "id": rs_id, "attributes": {"submitted": True}}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
