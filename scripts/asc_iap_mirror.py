"""Copy the live in-app purchase catalog into Trubbo Beta, and upload IAP review screenshots (#234).

Product ids are unique across the developer account, so the beta app (com.missinghue.hangs.beta) sells
every product of store_copy.json `in_app_purchases` as `beta.` + the live id. Steps of asc_store_upload.py:

  iap-mirror  create each missing prefixed product in the target app from its live twin: type, reference
              name, review note, base price (subscriptions: the USA price, equalized to every territory),
              availability; subscriptions in a group with the live group's reference name. Existing
              products are never changed.
  iap-review  upload the App Store review screenshot of every store_copy product that has none
              (fastlane/iap_review/<live id>.png). Without it a product never leaves Missing Metadata,
              and in the beta that means no sandbox purchase (Ready to Submit is enough there).

Texts come from the `iap` step as usual. Helpers live in asc_store_upload, passed in as `up` (that module
is usually `__main__`, so importing it here would read a second copy with APPLY off).
"""

from __future__ import annotations

import hashlib
from decimal import Decimal
from types import ModuleType

import requests
from asc_audit import get, prices_with_points

LIVE_BUNDLE_ID = "com.missinghue.hangs"
SUB_BASE_TERRITORY = "USA"
# The paywall shot shows both plans; the subscription has no shot of its own (it was submitted before
# review screenshots were kept in the repo).
PAYWALL_SHOT = "com.carquiz.pack.questions100.png"


def wanted_live_ids(copy: dict) -> list[str]:
    return [pid for pid in copy["in_app_purchases"] if pid != "subscription_group" and not pid.startswith("_")]


def live_catalog(up: ModuleType, app_id: str) -> tuple[dict, dict, dict]:
    """(consumables/non-consumables by id, subscriptions by id, subscription group by subscription id)."""
    iaps = {p["attributes"]["productId"]: p for p in up.all_pages(f"/apps/{app_id}/inAppPurchasesV2", limit=200)}
    subs, groups = {}, {}
    for g in up.all_pages(f"/apps/{app_id}/subscriptionGroups", limit=50):
        for s in up.all_pages(f"/subscriptionGroups/{g['id']}/subscriptions", limit=50):
            subs[s["attributes"]["productId"]] = s
            groups[s["attributes"]["productId"]] = g
    return iaps, subs, groups


def step_iap_mirror(up: ModuleType, app_id: str, live_app_id: str, prefix: str, copy: dict) -> None:
    print("iap-mirror")
    if not prefix or app_id == live_app_id:
        raise SystemExit("  !! iap-mirror copies the live catalog into another app under a product id prefix")
    live_iaps, live_subs, live_groups = live_catalog(up, live_app_id)
    have_iaps, have_subs, _ = live_catalog(up, app_id)
    for live_id in wanted_live_ids(copy):
        pid = prefix + live_id
        if live_id in live_iaps:
            mirror_iap(up, app_id, pid, live_iaps[live_id], have_iaps.get(pid))
        elif live_id in live_subs:
            mirror_subscription(up, app_id, pid, live_subs[live_id], live_groups[live_id], have_subs.get(pid))
        else:
            raise SystemExit(f"  !! {live_id}: not in the live app (create it there first)")


def mirror_iap(up: ModuleType, app_id: str, pid: str, live: dict, cur: dict | None) -> None:
    base, manual = up.iap_base_price(live["id"])
    avail = up.iap_availability(live["id"])
    price = next((m.get("customerPrice") for m in manual if m["territory"] == base), None)
    if not base or price is None or not avail:
        raise SystemExit(f"  !! {live['attributes']['productId']}: live product has no base price or availability")
    if cur:
        iap_id = cur["id"]
        need_price, need_avail = up.iap_base_price(iap_id)[0] is None, up.iap_availability(iap_id) is None
        print(f"  {pid}: exists ({cur['attributes']['state']}), price set={not need_price}, availability set={not need_avail}")
    else:
        a = live["attributes"]
        res = up.send("POST", f"{up.V2}/inAppPurchases", {"data": {"type": "inAppPurchases", "attributes": {
            "name": a["name"], "productId": pid, "inAppPurchaseType": a["inAppPurchaseType"], "reviewNote": a.get("reviewNote")},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        iap_id = res.get("data", {}).get("id")
        need_price = need_avail = True
    if need_price:
        point = up.iap_price_point(iap_id or live["id"], base, price)  # dry run: the live product's tiers
        print(f"  {pid}: price {base} {point['attributes']['customerPrice']}")
        up.set_base_price(iap_id, base, point["id"])
    if need_avail:
        up.send("POST", "/inAppPurchaseAvailabilities", {"data": {"type": "inAppPurchaseAvailabilities",
            "attributes": {"availableInNewTerritories": avail[0]}, "relationships": {
                "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                "availableTerritories": {"data": [{"type": "territories", "id": t} for t in avail[1]]}}}})


def subscription_availability(up: ModuleType, sub_id: str) -> tuple[bool, list[str]] | None:
    av = get(f"/subscriptions/{sub_id}/subscriptionAvailability")
    if "_error" in av or not av.get("data"):
        return None
    terrs = up.all_pages(f"/subscriptionAvailabilities/{av['data']['id']}/availableTerritories", limit=200)
    return av["data"]["attributes"].get("availableInNewTerritories"), [t["id"] for t in terrs]


def find_or_create_group(up: ModuleType, app_id: str, reference_name: str) -> str | None:
    groups = up.all_pages(f"/apps/{app_id}/subscriptionGroups", limit=50)
    hit = next((g for g in groups if g["attributes"]["referenceName"] == reference_name), None)
    if hit:
        return hit["id"]
    res = up.send("POST", "/subscriptionGroups", {"data": {"type": "subscriptionGroups", "attributes": {
        "referenceName": reference_name}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    return res.get("data", {}).get("id")


def mirror_subscription(up: ModuleType, app_id: str, pid: str, live: dict, live_group: dict, cur: dict | None) -> None:
    avail = subscription_availability(up, live["id"])
    live_prices = prices_with_points(get(f"/subscriptions/{live['id']}/prices", include="subscriptionPricePoint,territory", limit=200),
                                     "subscriptionPricePoint")
    price = next((p.get("customerPrice") for p in live_prices if p["territory"] == SUB_BASE_TERRITORY), None)
    if not avail or price is None:
        raise SystemExit(f"  !! {live['attributes']['productId']}: live subscription has no availability or {SUB_BASE_TERRITORY} price")
    if cur:
        sub_id = cur["id"]
        prices = get(f"/subscriptions/{sub_id}/prices", limit=1)
        need_price = not prices.get("data")
        need_avail = subscription_availability(up, sub_id) is None
        print(f"  {pid}: exists ({cur['attributes']['state']}), price set={not need_price}, availability set={not need_avail}")
    else:
        group_id = find_or_create_group(up, app_id, live_group["attributes"]["referenceName"])
        a = live["attributes"]
        attributes = {"name": a["name"], "productId": pid, "subscriptionPeriod": a["subscriptionPeriod"],
            "reviewNote": a.get("reviewNote"), "familySharable": a.get("familySharable") or False,
            "groupLevel": a.get("groupLevel") or 1}
        # ASC answers 500 (not 409/422) on null attributes, so send only the set ones.
        res = up.send("POST", "/subscriptions", {"data": {"type": "subscriptions", "attributes": {
            k: v for k, v in attributes.items() if v is not None},
            "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": group_id or "<new>"}}}}})
        sub_id = res.get("data", {}).get("id")
        need_price = need_avail = True
    if need_avail:
        up.send("POST", "/subscriptionAvailabilities", {"data": {"type": "subscriptionAvailabilities",
            "attributes": {"availableInNewTerritories": avail[0]}, "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "availableTerritories": {"data": [{"type": "territories", "id": t} for t in avail[1]]}}}})
    if need_price:
        # Subscriptions have no base-territory equalization like IAPs: price every available territory
        # with Apple's equalized point of the USA price. Dry run: the live subscription's tiers.
        points = up.all_pages(f"/subscriptions/{sub_id or live['id']}/pricePoints", limit=200,
                              **{"filter[territory]": SUB_BASE_TERRITORY})
        base = next((p for p in points if Decimal(p["attributes"]["customerPrice"]) == Decimal(price)), None)
        if not base:
            raise SystemExit(f"  !! no subscription price point {price} in {SUB_BASE_TERRITORY}")
        eq = up.all_pages(f"/subscriptionPricePoints/{base['id']}/equalizations", limit=200, include="territory")
        targets = [(SUB_BASE_TERRITORY, base["id"])] + [
            ((p.get("relationships", {}).get("territory", {}).get("data") or {}).get("id"), p["id"]) for p in eq]
        targets = [(t, p) for t, p in targets if t in set(avail[1])]
        print(f"  {pid}: price {SUB_BASE_TERRITORY} {price}, equalized to {len(targets)} territories")
        for territory, point_id in targets:
            up.send("POST", "/subscriptionPrices", {"data": {"type": "subscriptionPrices",
                "attributes": {"startDate": None, "preserveCurrentPrice": False}, "relationships": {
                    "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                    "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": point_id}},
                    "territory": {"data": {"type": "territories", "id": territory}}}}})


def upload_review_screenshot(up: ModuleType, kind: str, item: dict, shot) -> None:
    """kind: "inAppPurchase" (v2 product) or "subscription". Idempotent: a COMPLETE screenshot is kept."""
    pid = item["attributes"]["productId"]
    res_type = f"{kind}AppStoreReviewScreenshots"
    if kind == "inAppPurchase":
        cur = get(f"{up.V2}/inAppPurchases/{item['id']}/appStoreReviewScreenshot")
        rel = {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": item["id"]}}}
    else:
        cur = get(f"/subscriptions/{item['id']}/appStoreReviewScreenshot")
        rel = {"subscription": {"data": {"type": "subscriptions", "id": item["id"]}}}
    if cur.get("data"):
        state = (cur["data"]["attributes"].get("assetDeliveryState") or {}).get("state")
        print(f"    {pid}: existing screenshot {state}")
        if state == "COMPLETE":
            return
        up.send("DELETE", f"/{res_type}/{cur['data']['id']}")  # stale upload blocks a new one (409)
    if not shot.exists():
        raise SystemExit(f"  !! {pid}: no review screenshot in ASC and none at {shot}")
    data = shot.read_bytes()
    res = up.send("POST", f"/{res_type}", {"data": {"type": res_type, "attributes": {"fileName": shot.name, "fileSize": len(data)},
                                                    "relationships": rel}})
    if not up.APPLY:
        return
    for op in res["data"]["attributes"]["uploadOperations"]:
        hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        requests.request(op["method"], op["url"], headers=hdrs, data=data[op["offset"]: op["offset"] + op["length"]], timeout=120).raise_for_status()
    sid = res["data"]["id"]
    up.send("PATCH", f"/{res_type}/{sid}", {"data": {"type": res_type, "id": sid,
                                                     "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


def step_iap_review(up: ModuleType, app_id: str, prefix: str, copy: dict) -> None:
    print("iap-review")
    shots = up.FL / "iap_review"
    iaps, subs, _ = live_catalog(up, app_id)
    for live_id in wanted_live_ids(copy):
        pid = prefix + live_id
        if pid in iaps:
            upload_review_screenshot(up, "inAppPurchase", iaps[pid], shots / f"{live_id}.png")
        elif pid in subs:
            own = shots / f"{live_id}.png"
            upload_review_screenshot(up, "subscription", subs[pid], own if own.exists() else shots / PAYWALL_SHOT)
        else:
            print(f"  {pid}: not in this app (run iap-mirror / iap-create first)")
