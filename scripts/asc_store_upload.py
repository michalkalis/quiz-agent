"""Push App Store listing + TestFlight beta info from the repo to App Store Connect (issue #190).

Sources of truth (all in apps/ios-app/Hangs/fastlane/):
  metadata/<locale>/*.txt            listing texts (fastlane deliver layout)
  metadata/review_information/*.txt  App Review contact + notes (phone comes from the
                                     ASC_REVIEW_PHONE secret: the repo is public)
  metadata/copyright.txt, primary_category.txt
  store_copy.json                    TestFlight Test Information, What to Test, IAP texts
  screenshots/<locale>/NN-*.jpg      6.9" iPhone screenshots (1320x2868)

Dry run by default (prints what would change). `--apply` writes. Steps are opt-in:
  python scripts/asc_store_upload.py --steps listing,review,testflight,iap,screenshots,beta-group [--build 66 [--submit-beta-review]] --apply
Runs in CI with the ASC_API_* secrets (see .github/workflows/asc-store-upload.yml).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

import requests
from asc_audit import BASE, BUNDLE_ID, HEADERS, get

FL = Path(__file__).resolve().parents[1] / "apps/ios-app/Hangs/fastlane"
MD = FL / "metadata"
LOCALES = ["en-GB", "en-US", "sk", "cs"]
APPLY = False


def txt(path: Path) -> str | None:
    return path.read_text().strip() if path.exists() else None


def send(method: str, path: str, body: dict | None = None) -> dict:
    data = (body or {}).get("data")
    shown = data.get("attributes", {}) if isinstance(data, dict) else data  # relationship linkage is a list
    print(f"  {method} {path} {json.dumps(shown, ensure_ascii=False)[:160] if body else ''}")
    if not APPLY:
        return {}
    r = requests.request(method, f"{BASE}{path}", headers={**HEADERS, "Content-Type": "application/json"}, json=body, timeout=60)
    if r.status_code >= 300:
        print(f"  !! {r.status_code} {r.text[:600]}")
        raise SystemExit(1)
    return r.json() if r.text else {}


def upsert(kind: str, existing: list[dict], locale: str, attrs: dict, rel: tuple[str, str, str]) -> None:
    """Create or patch a localization resource of type `kind` for `locale`."""
    attrs = {k: v for k, v in attrs.items() if v is not None}
    cur = next((e for e in existing if e["attributes"].get("locale") == locale), None)
    if cur:
        diff = {k: v for k, v in attrs.items() if cur["attributes"].get(k) != v}
        if diff:
            send("PATCH", f"/{kind}/{cur['id']}", {"data": {"type": kind, "id": cur["id"], "attributes": diff}})
    else:
        rel_name, rel_type, rel_id = rel
        send("POST", f"/{kind}", {"data": {"type": kind, "attributes": {"locale": locale, **attrs},
                                           "relationships": {rel_name: {"data": {"type": rel_type, "id": rel_id}}}}})


def editable_version(app_id: str) -> dict:
    versions = get(f"/apps/{app_id}/appStoreVersions", **{"filter[appStoreState]": "PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED"})
    return versions["data"][0]


def step_listing(app_id: str) -> None:
    print("listing")
    info = next(i for i in get(f"/apps/{app_id}/appInfos")["data"] if i["attributes"].get("state") != "READY_FOR_DISTRIBUTION")
    cat = txt(MD / "primary_category.txt")
    cur_cat = (get(f"/appInfos/{info['id']}/primaryCategory").get("data") or {}).get("id")
    if cat and cur_cat != cat:
        send("PATCH", f"/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"],
                                                         "relationships": {"primaryCategory": {"data": {"type": "appCategories", "id": cat}}}}})
    existing = get(f"/appInfos/{info['id']}/appInfoLocalizations").get("data", [])
    for loc in LOCALES:
        d = MD / loc
        upsert("appInfoLocalizations", existing, loc,
               {"name": txt(d / "name.txt"), "subtitle": txt(d / "subtitle.txt"), "privacyPolicyUrl": txt(d / "privacy_url.txt")},
               ("appInfo", "appInfos", info["id"]))
    ver = editable_version(app_id)
    copyright_ = txt(MD / "copyright.txt")
    if copyright_ and ver["attributes"].get("copyright") != copyright_:
        send("PATCH", f"/appStoreVersions/{ver['id']}", {"data": {"type": "appStoreVersions", "id": ver["id"], "attributes": {"copyright": copyright_}}})
    existing = get(f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations").get("data", [])
    for loc in LOCALES:
        d = MD / loc
        # whatsNew is rejected on a first version, so release_notes.txt is not sent.
        upsert("appStoreVersionLocalizations", existing, loc,
               {"description": txt(d / "description.txt"), "keywords": txt(d / "keywords.txt"),
                "promotionalText": txt(d / "promotional_text.txt"), "supportUrl": txt(d / "support_url.txt"),
                "marketingUrl": txt(d / "marketing_url.txt")},
               ("appStoreVersion", "appStoreVersions", ver["id"]))


def review_contact() -> dict:
    ri = MD / "review_information"
    return {"contactFirstName": txt(ri / "first_name.txt"), "contactLastName": txt(ri / "last_name.txt"),
            "contactPhone": os.environ.get("ASC_REVIEW_PHONE"), "contactEmail": txt(ri / "email_address.txt"),
            "demoAccountRequired": False, "notes": txt(ri / "notes.txt")}


def step_review(app_id: str) -> None:
    print("review")
    ver = editable_version(app_id)
    cur = get(f"/appStoreVersions/{ver['id']}/appStoreReviewDetail").get("data")
    attrs = review_contact()
    if cur:
        send("PATCH", f"/appStoreReviewDetails/{cur['id']}", {"data": {"type": "appStoreReviewDetails", "id": cur["id"], "attributes": attrs}})
    else:
        send("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                                                         "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver["id"]}}}}})


def step_testflight(app_id: str, copy: dict, build: str | None) -> None:
    print("testflight")
    tf = copy["testflight"]
    existing = get(f"/apps/{app_id}/betaAppLocalizations").get("data", [])
    for loc in LOCALES:
        upsert("betaAppLocalizations", existing, loc,
               {"description": tf["beta_description"][loc], "feedbackEmail": tf["feedback_email"], "privacyPolicyUrl": tf["privacy_policy_url"]},
               ("app", "apps", app_id))
    contact = {k: v for k, v in review_contact().items() if v is not None}
    send("PATCH", f"/betaAppReviewDetails/{app_id}", {"data": {"type": "betaAppReviewDetails", "id": app_id, "attributes": contact}})
    if build:
        b = get("/builds", **{"filter[app]": app_id, "filter[version]": build})["data"][0]
        existing = get(f"/builds/{b['id']}/betaBuildLocalizations").get("data", [])
        for loc in LOCALES:
            upsert("betaBuildLocalizations", existing, loc, {"whatsNew": tf["what_to_test"][loc]}, ("build", "builds", b["id"]))


def step_iap(app_id: str, copy: dict) -> None:
    print("iap")
    iap = copy["in_app_purchases"]
    for p in get(f"/apps/{app_id}/inAppPurchasesV2", limit=50).get("data", []):
        texts = iap.get(p["attributes"]["productId"])
        if not texts:
            continue
        existing = get(f"/inAppPurchases/{p['id']}/inAppPurchaseLocalizations").get("data", [])
        for loc in LOCALES:
            name, desc = texts[loc]
            upsert("inAppPurchaseLocalizations", existing, loc, {"name": name, "description": desc}, ("inAppPurchaseV2", "inAppPurchases", p["id"]))
    for g in get(f"/apps/{app_id}/subscriptionGroups", limit=20).get("data", []):
        existing = get(f"/subscriptionGroups/{g['id']}/subscriptionGroupLocalizations").get("data", [])
        for loc in LOCALES:
            upsert("subscriptionGroupLocalizations", existing, loc, {"name": iap["subscription_group"][loc]}, ("subscriptionGroup", "subscriptionGroups", g["id"]))
        for s in get(f"/subscriptionGroups/{g['id']}/subscriptions", limit=20).get("data", []):
            texts = iap.get(s["attributes"]["productId"])
            if not texts:  # annual stays untouched and unsubmitted (founder 2026-10-07)
                continue
            existing = get(f"/subscriptions/{s['id']}/subscriptionLocalizations").get("data", [])
            for loc in LOCALES:
                name, desc = texts[loc]
                upsert("subscriptionLocalizations", existing, loc, {"name": name, "description": desc}, ("subscription", "subscriptions", s["id"]))


def step_screenshots(app_id: str) -> None:
    print("screenshots")
    ver = editable_version(app_id)
    locs = {l["attributes"]["locale"]: l for l in get(f"/appStoreVersions/{ver['id']}/appStoreVersionLocalizations").get("data", [])}
    for loc in LOCALES:
        files = sorted((FL / "screenshots" / loc).glob("*.jpg")) or sorted((FL / "screenshots" / loc.split("-")[0]).glob("*.jpg"))
        if not files or loc not in locs:
            print(f"  skip {loc}: {'no files' if not files else 'no version localization yet (run listing first)'}")
            continue
        lid = locs[loc]["id"]
        sets = get(f"/appStoreVersionLocalizations/{lid}/appScreenshotSets", include="appScreenshots").get("data", [])
        cur = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_IPHONE_67"), None)
        if cur:  # replace the whole set so order and content match the repo
            for shot in cur.get("relationships", {}).get("appScreenshots", {}).get("data", []):
                send("DELETE", f"/appScreenshots/{shot['id']}")
            set_id = cur["id"]
        else:
            res = send("POST", "/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"},
                                                               "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})
            set_id = res.get("data", {}).get("id", "<new>")
        for f in files:
            data = f.read_bytes()
            res = send("POST", "/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": f.name, "fileSize": len(data)},
                                                            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
            if not APPLY:
                continue
            for op in res["data"]["attributes"]["uploadOperations"]:
                chunk = data[op["offset"]: op["offset"] + op["length"]]
                hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
                requests.request(op["method"], op["url"], headers=hdrs, data=chunk, timeout=120).raise_for_status()
            send("PATCH", f"/appScreenshots/{res['data']['id']}", {"data": {"type": "appScreenshots", "id": res["data"]["id"],
                                                                         "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


PUBLIC_GROUP = "Public beta"
PUBLIC_LINK_LIMIT = 50  # founder 2026-10-07: public link with a tester limit


def step_beta_group(app_id: str, build: str | None, submit: bool) -> None:
    """External group with a capped public link; optionally add `build` and submit it to Beta App Review."""
    print("beta-group")
    groups = get(f"/apps/{app_id}/betaGroups", limit=50).get("data", [])
    group = next((g for g in groups if g["attributes"]["name"] == PUBLIC_GROUP), None)
    if not group:
        res = send("POST", "/betaGroups", {"data": {"type": "betaGroups", "attributes": {
            "name": PUBLIC_GROUP, "publicLinkEnabled": True, "publicLinkLimitEnabled": True,
            "publicLinkLimit": PUBLIC_LINK_LIMIT, "feedbackEnabled": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        group = res.get("data", {"id": "<new>", "attributes": {}})
    print(f"  public link: {group['attributes'].get('publicLink')}")
    if not build:
        return
    b = get("/builds", **{"filter[app]": app_id, "filter[version]": build})["data"][0]
    send("POST", f"/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": b["id"]}]})
    if submit:
        send("POST", "/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
                                                            "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})


def main() -> int:
    global APPLY
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", default="listing,review,testflight,iap")
    ap.add_argument("--build", help="build number that gets What to Test")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--submit-beta-review", action="store_true", help="with beta-group + --build: submit the build to Beta App Review")
    args = ap.parse_args()
    APPLY = args.apply
    print("APPLY" if APPLY else "DRY RUN (pass --apply to write)")
    app_id = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]
    copy = json.loads((FL / "store_copy.json").read_text())
    steps = args.steps.split(",")
    if "listing" in steps:
        step_listing(app_id)
    if "review" in steps:
        step_review(app_id)
    if "testflight" in steps:
        step_testflight(app_id, copy, args.build)
    if "iap" in steps:
        step_iap(app_id, copy)
    if "screenshots" in steps:
        step_screenshots(app_id)
    if "beta-group" in steps:
        step_beta_group(app_id, args.build, args.submit_beta_review)
    return 0


if __name__ == "__main__":
    sys.exit(main())
