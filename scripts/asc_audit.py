"""Read-only App Store Connect audit: products, prices, localizations, availability.

Runs in CI with ASC_API_* secrets; prints a JSON summary. GET requests only.
"""

from __future__ import annotations

import json
import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("ASC_AUDIT_BUNDLE_ID", "com.missinghue.hangs")
TERRITORIES = os.environ.get("ASC_AUDIT_TERRITORIES", "SVK,CZE,USA,GBR,DEU,POL,HUN,AUT").split(",")


def token() -> str:
    key = os.environ["ASC_API_KEY_CONTENT"]
    if os.environ.get("ASC_API_KEY_CONTENT_IS_BASE64") == "true":
        import base64

        key = base64.b64decode(key).decode()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_API_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_API_KEY_ID"]},
    )


HEADERS = {"Authorization": f"Bearer {token()}"}


def get(path: str, **params):
    url = path if path.startswith("http") else f"{BASE}{path}"
    r = requests.get(url, headers=HEADERS, params=params, timeout=30)
    if r.status_code != 200:
        return {"_error": r.status_code, "_body": r.text[:400]}
    return r.json()


def attrs(item):
    return {"id": item.get("id"), **item.get("attributes", {})}


def included_map(payload):
    return {(i["type"], i["id"]): i for i in payload.get("included", [])}


def prices_with_points(payload, rel_point: str):
    inc = included_map(payload)
    out = []
    for p in payload.get("data", []):
        rel = p.get("relationships", {})
        pp = rel.get(rel_point, {}).get("data") or {}
        terr = rel.get("territory", {}).get("data") or {}
        point = inc.get((pp.get("type"), pp.get("id")), {}).get("attributes", {})
        row = {"territory": terr.get("id"), **p.get("attributes", {}), **point}
        if not terr.get("id") and point:
            t2 = inc.get((pp.get("type"), pp.get("id")), {}).get("relationships", {}).get("territory", {}).get("data") or {}
            row["territory"] = t2.get("id")
        out.append(row)
    return out


def main() -> int:
    report: dict = {}
    apps = get("/apps", **{"filter[bundleId]": BUNDLE_ID, "fields[apps]": "name,bundleId,primaryLocale,sku,contentRightsDeclaration"})
    if "_error" in apps or not apps.get("data"):
        print(json.dumps({"apps": apps}, indent=1))
        return 1
    app = apps["data"][0]
    app_id = app["id"]
    report["app"] = attrs(app)

    versions = get(f"/apps/{app_id}/appStoreVersions", limit=5, **{"fields[appStoreVersions]": "versionString,appStoreState,platform,createdDate"})
    report["appStoreVersions"] = [attrs(v) for v in versions.get("data", [])]

    infos = get(f"/apps/{app_id}/appInfos", include="appInfoLocalizations", limit=2)
    report["appInfoLocalizations"] = [
        {k: v for k, v in i["attributes"].items() if k in ("locale", "name", "subtitle")}
        for i in infos.get("included", []) if i["type"] == "appInfoLocalizations"
    ]
    report["appInfos_state"] = [attrs(i).get("state") for i in infos.get("data", [])]

    price = get(f"/apps/{app_id}/appPriceSchedule", include="manualPrices,baseTerritory")
    report["appPriceSchedule"] = {
        "baseTerritory": (price.get("data", {}).get("relationships", {}).get("baseTerritory", {}).get("data") or {}).get("id"),
        "manualPrices": [attrs(i) for i in price.get("included", []) if i["type"] == "appPrices"],
    } if "_error" not in price else price

    avail = get(f"/apps/{app_id}/appAvailabilityV2", include="territoryAvailabilities", limit=200)
    if "_error" not in avail:
        ta = [i for i in avail.get("included", []) if i["type"] == "territoryAvailabilities"]
        report["availability"] = {
            "availableInNewTerritories": avail.get("data", {}).get("attributes", {}).get("availableInNewTerritories"),
            "territoriesIncludedInFirstPage": len(ta),
            "availableCount": sum(1 for t in ta if t["attributes"].get("available")),
            "sample": [(t["attributes"].get("territoryId") or t["id"]) for t in ta[:5]],
            "watch": {t["attributes"].get("territoryId") or t["id"]: t["attributes"].get("available") for t in ta if (t["attributes"].get("territoryId") or t["id"]) in TERRITORIES},
        }
    else:
        report["availability"] = avail

    # --- consumables / non-consumables
    iaps = get(f"/apps/{app_id}/inAppPurchasesV2", limit=50)
    report["inAppPurchases"] = []
    for iap in iaps.get("data", []):
        row = attrs(iap)
        iid = iap["id"]
        loc = get(f"/inAppPurchases/{iid}/inAppPurchaseLocalizations")
        row["localizations"] = [attrs(l) for l in loc.get("data", [])]
        sched = get(f"/inAppPurchases/{iid}/iapPriceSchedule", include="baseTerritory")
        if "_error" not in sched and sched.get("data"):
            sid = sched["data"]["id"]
            row["baseTerritory"] = (sched["data"].get("relationships", {}).get("baseTerritory", {}).get("data") or {}).get("id")
            manual = get(f"/inAppPurchasePriceSchedules/{sid}/manualPrices", include="inAppPurchasePricePoint,territory", limit=200)
            row["manualPrices"] = prices_with_points(manual, "inAppPurchasePricePoint")
            auto = get(f"/inAppPurchasePriceSchedules/{sid}/automaticPrices", include="inAppPurchasePricePoint,territory", limit=200, **{"filter[territory]": ",".join(TERRITORIES)})
            row["automaticPrices_watch"] = prices_with_points(auto, "inAppPurchasePricePoint")
        else:
            row["priceSchedule"] = sched
        shot = get(f"/inAppPurchases/{iid}/appStoreReviewScreenshot")
        row["reviewScreenshot"] = attrs(shot["data"]).get("assetDeliveryState") if shot.get("data") else shot.get("_error", "none")
        av = get(f"/inAppPurchases/{iid}/inAppPurchaseAvailability", include="availableTerritories", limit=200)
        row["availability"] = {"availableInNewTerritories": av.get("data", {}).get("attributes", {}).get("availableInNewTerritories"), "territoryCount": len(av.get("included", []))} if "_error" not in av else av
        report["inAppPurchases"].append(row)

    # --- subscriptions
    groups = get(f"/apps/{app_id}/subscriptionGroups", limit=20)
    report["subscriptionGroups"] = []
    for g in groups.get("data", []):
        grow = attrs(g)
        gid = g["id"]
        gl = get(f"/subscriptionGroups/{gid}/subscriptionGroupLocalizations")
        grow["localizations"] = [attrs(l) for l in gl.get("data", [])]
        subs = get(f"/subscriptionGroups/{gid}/subscriptions", limit=20)
        grow["subscriptions"] = []
        for s in subs.get("data", []):
            srow = attrs(s)
            sid = s["id"]
            sl = get(f"/subscriptions/{sid}/subscriptionLocalizations")
            srow["localizations"] = [attrs(l) for l in sl.get("data", [])]
            pr = get(f"/subscriptions/{sid}/prices", include="subscriptionPricePoint,territory", limit=200, **{"filter[territory]": ",".join(TERRITORIES)})
            srow["prices_watch"] = prices_with_points(pr, "subscriptionPricePoint")
            pr_all = get(f"/subscriptions/{sid}/prices", limit=200)
            srow["price_rows_total_first_page"] = len(pr_all.get("data", []))
            intro = get(f"/subscriptions/{sid}/introductoryOffers", limit=50)
            srow["introductoryOffers"] = [attrs(i) for i in intro.get("data", [])]
            promo = get(f"/subscriptions/{sid}/promotionalOffers", limit=50)
            srow["promotionalOffers"] = [attrs(i) for i in promo.get("data", [])]
            shot = get(f"/subscriptions/{sid}/appStoreReviewScreenshot")
            srow["reviewScreenshot"] = attrs(shot["data"]).get("assetDeliveryState") if shot.get("data") else shot.get("_error", "none")
            av = get(f"/subscriptions/{sid}/subscriptionAvailability", include="availableTerritories", limit=200)
            srow["availability"] = {"availableInNewTerritories": av.get("data", {}).get("attributes", {}).get("availableInNewTerritories"), "territoryCount": len(av.get("included", []))} if "_error" not in av else av
            grow["subscriptions"].append(srow)
        report["subscriptionGroups"].append(grow)

    print("=== ASC AUDIT REPORT ===")
    print(json.dumps(report, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
