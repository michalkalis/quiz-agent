"""Add a TestFlight tester to a named group (skill /add-tester, docs/setup/release-flow.md).

Internal groups (Founder, family+friends) only take App Store Connect users, so a new person first
gets a user invitation (role Customer Support, Trubbo only); rerun after they accept it.
External group (Public beta) takes any e-mail and Apple sends the TestFlight invite right away.

Dry run by default:
  python scripts/asc_add_tester.py --email a@b.c --first-name A --last-name B --group "family+friends" [--apply]
Runs in CI with the ASC_API_* secrets (see .github/workflows/asc-add-tester.yml). Idempotent.
"""

from __future__ import annotations

import argparse
import sys

import asc_store_upload as up
from asc_audit import BUNDLE_ID, get


def add_tester(app_id: str, email: str, first: str, last: str, group_name: str) -> None:
    group = up.find_group(app_id, group_name)
    if not group:
        raise SystemExit(f"!! group '{group_name}' missing (run asc-store-upload groups-setup first)")
    if get("/betaTesters", **{"filter[email]": email, "filter[betaGroups]": group["id"]}).get("data"):
        print(f"done: already a tester in {group_name}")
        return

    if group["attributes"].get("isInternalGroup") and not get("/users", **{"filter[username]": email}).get("data"):
        if get("/userInvitations", **{"filter[email]": email}).get("data"):
            print("pending: App Store Connect invitation not accepted yet; rerun after the tester accepts it")
            return
        up.send("POST", "/userInvitations", {"data": {"type": "userInvitations", "attributes": {
            "email": email, "firstName": first, "lastName": last, "roles": ["CUSTOMER_SUPPORT"],
            "allAppsVisible": False, "provisioningAllowed": False},
            "relationships": {"visibleApps": {"data": [{"type": "apps", "id": app_id}]}}}})
        print("invited: tester must accept the App Store Connect e-mail, then rerun to add them to the group")
        return

    existing = get("/betaTesters", **{"filter[email]": email, "filter[apps]": app_id}).get("data", [])
    if existing:
        up.send("POST", f"/betaGroups/{group['id']}/relationships/betaTesters",
                {"data": [{"type": "betaTesters", "id": existing[0]["id"]}]})
    else:
        up.send("POST", "/betaTesters", {"data": {"type": "betaTesters", "attributes": {
            "email": email, "firstName": first, "lastName": last},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
    print(f"done: added to {group_name}; TestFlight invite e-mail goes out from Apple")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", required=True)
    ap.add_argument("--first-name", default="")
    ap.add_argument("--last-name", default="")
    ap.add_argument("--group", required=True, choices=up.PROMOTE_GROUPS)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    up.APPLY = args.apply
    print("APPLY" if args.apply else "DRY RUN (pass --apply to write)")
    app_id = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]
    add_tester(app_id, args.email.strip().lower(), args.first_name, args.last_name, args.group)
    return 0


if __name__ == "__main__":
    sys.exit(main())
