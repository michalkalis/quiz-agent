"""#212.1 same-room multiplayer rooms.

What matters: a guest on the host's Wi-Fi finds the game without typing
anything — also on dual-stack networks, where every phone has its own IPv6
address and only the /64 prefix is shared — while nobody off that network can
see or join it without the QR/link token, and a guest can never steer the
host's game or end it.
"""

from __future__ import annotations

import time

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from quiz_shared.models.phase import SessionPhase

from app.api.routes import rooms as room_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter
from app.rooms.network import NetTickets, collect_keys, network_key
from app.rooms.service import MAX_PLAYERS, RoomService
from app.rooms.store import MemoryRoomStore
from app.session.manager import SessionManager

_SECRET = "r" * 64
HOME_V4 = "84.245.1.10"
HOME_V6_HOST = "2a02:8070:1:2:aaaa:1:2:3"
HOME_V6_GUEST = "2a02:8070:1:2:bbbb:9:8:7"  # same /64, different phone
OTHER_V4 = "93.184.216.34"
OTHER_V6 = "2a02:8070:1:3::5"  # neighbouring /64


def _tokens() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _h(subject: str, ip: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {_tokens().create_access_token(subject)}",
        "Fly-Client-IP": ip,
    }


# ── network keys ─────────────────────────────────────────────────────────


def test_ipv6_phones_on_one_network_share_the_64_prefix():
    assert network_key(HOME_V6_HOST) == network_key(HOME_V6_GUEST)
    assert network_key(HOME_V6_HOST) != network_key(OTHER_V6)


def test_ipv4_is_matched_exactly_and_mapped_addresses_count_as_ipv4():
    assert network_key(HOME_V4) == f"v4:{HOME_V4}"
    assert network_key(f"::ffff:{HOME_V4}") == f"v4:{HOME_V4}"


@pytest.mark.parametrize("ip", ["127.0.0.1", "10.0.0.5", "192.168.1.2", "fe80::1", ""])
def test_private_addresses_never_form_a_network(ip):
    # Local dev / a proxy hiding the client would put everyone in one room.
    assert network_key(ip) is None


def test_a_ticket_is_bound_to_its_subject_and_expires():
    signer = NetTickets(_SECRET)
    ticket = signer.issue("anon-a", "v6:2a02:8070:1:2::/64")
    assert signer.verify(ticket, "anon-a") == "v6:2a02:8070:1:2::/64"
    assert signer.verify(ticket, "anon-b") is None
    assert signer.verify(ticket, "anon-a", now=time.time() + 3600) is None
    body, sig = ticket.split(".")
    assert signer.verify(f"{body}x.{sig}", "anon-a") is None


def test_the_request_address_wins_over_a_ticket_of_the_same_family():
    signer = NetTickets(_SECRET)
    stale = signer.issue("s", f"v4:{OTHER_V4}")
    keys = collect_keys(HOME_V4, [stale], "s", signer)
    assert keys == {"v4": f"v4:{HOME_V4}"}


# ── routes ───────────────────────────────────────────────────────────────


@pytest_asyncio.fixture
async def ctx(monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    limiter.reset()
    sessions = SessionManager()
    service = RoomService(sessions, MemoryRoomStore(), NetTickets(_SECRET))
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(room_routes.router, prefix="/api/v1")
    app.state.token_service = _tokens()
    app.state.rooms = service
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c, sessions, service


async def _host_room(client, sessions, ip=HOME_V4, tickets=()):
    session = await sessions.create_session(user_id="host")
    resp = await client.post(
        "/api/v1/rooms",
        json={
            "session_id": session.session_id,
            "host_name": "Michal",
            "net_tickets": list(tickets),
        },
        headers=_h("host", ip),
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _nearby(client, subject, ip, tickets=()):
    resp = await client.post(
        "/api/v1/rooms/nearby",
        json={"net_tickets": list(tickets)},
        headers=_h(subject, ip),
    )
    assert resp.status_code == 200, resp.text
    return [r["room_id"] for r in resp.json()["rooms"]]


async def _probe(client, subject, ip):
    resp = await client.get("/api/v1/rooms/net-probe", headers=_h(subject, ip))
    assert resp.status_code == 200
    return resp.json()["ticket"]


@pytest.mark.asyncio
async def test_switch_off_hides_every_endpoint(ctx, monkeypatch):
    client, sessions, _ = ctx
    monkeypatch.setenv("MULTIPLAYER_ENABLED", "false")
    resp = await client.post(
        "/api/v1/rooms/nearby", json={}, headers=_h("guest", HOME_V4)
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_requires_sign_in(ctx):
    client, _, _ = ctx
    resp = await client.post("/api/v1/rooms/nearby", json={})
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_only_the_session_owner_can_open_a_room(ctx):
    client, sessions, _ = ctx
    session = await sessions.create_session(user_id="host")
    resp = await client.post(
        "/api/v1/rooms",
        json={"session_id": session.session_id, "host_name": "X"},
        headers=_h("intruder", HOME_V4),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_creating_twice_returns_the_same_room(ctx):
    client, sessions, _ = ctx
    session = await sessions.create_session(user_id="host")
    body = {"session_id": session.session_id, "host_name": "Michal"}
    a = await client.post("/api/v1/rooms", json=body, headers=_h("host", HOME_V4))
    b = await client.post("/api/v1/rooms", json=body, headers=_h("host", HOME_V4))
    assert a.json() == b.json()


@pytest.mark.asyncio
async def test_guest_on_the_same_wifi_finds_the_game_strangers_do_not(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    assert await _nearby(client, "guest", HOME_V4) == [room["room_id"]]
    assert await _nearby(client, "stranger", OTHER_V4) == []
    assert await _nearby(client, "host", HOME_V4) == []  # not your own game


@pytest.mark.asyncio
async def test_dual_stack_host_on_ipv4_guest_on_ipv6_still_match(ctx):
    """Happy Eyeballs put the host on IPv4 and the guest on IPv6; the host's
    IPv6 probe ticket carries the shared /64."""
    client, sessions, _ = ctx
    v6_ticket = await _probe(client, "host", HOME_V6_HOST)
    room = await _host_room(client, sessions, ip=HOME_V4, tickets=[v6_ticket])
    assert await _nearby(client, "guest", HOME_V6_GUEST) == [room["room_id"]]
    assert await _nearby(client, "neighbour", OTHER_V6) == []


@pytest.mark.asyncio
async def test_ipv6_only_network_matches_on_the_prefix_alone(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions, ip=HOME_V6_HOST)
    assert await _nearby(client, "guest", HOME_V6_GUEST) == [room["room_id"]]


@pytest.mark.asyncio
async def test_a_ticket_from_someone_else_does_not_place_you_on_their_network(ctx):
    client, sessions, _ = ctx
    await _host_room(client, sessions)
    guest_ticket = await _probe(client, "guest", HOME_V4)
    assert await _nearby(client, "stranger", OTHER_V4, [guest_ticket]) == []


@pytest.mark.asyncio
async def test_join_by_id_needs_the_network_join_by_token_works_anywhere(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    far = await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "Jana", "room_id": room["room_id"]},
        headers=_h("far", OTHER_V4),
    )
    assert far.status_code == 404
    by_link = await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "Jana", "join_token": room["join_token"]},
        headers=_h("far", OTHER_V4),
    )
    assert by_link.status_code == 200
    near = await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "Peťo", "room_id": room["room_id"]},
        headers=_h("near", HOME_V4),
    )
    assert near.status_code == 200
    state = near.json()
    assert [p["display_name"] for p in state["players"]] == ["Michal", "Jana", "Peťo"]
    assert state["status"] == "lobby" and state["is_host"] is False
    # Every player gets their own colour.
    assert len({p["color"] for p in state["players"]}) == 3


@pytest.mark.asyncio
async def test_joining_again_does_not_add_a_second_player(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    body = {"display_name": "Jana", "join_token": room["join_token"]}
    for _ in range(2):
        resp = await client.post(
            "/api/v1/rooms/join", json=body, headers=_h("g", OTHER_V4)
        )
    assert len(resp.json()["players"]) == 2


@pytest.mark.asyncio
async def test_joining_again_in_the_lobby_renames_the_guest(ctx):
    """The guest's "tap your name to change it" goes through join: the name
    the others see changes, the player does not double."""
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    for name in ("Rýchly gepard", "Peťo"):
        resp = await client.post(
            "/api/v1/rooms/join",
            json={"display_name": name, "join_token": room["join_token"]},
            headers=_h("g", OTHER_V4),
        )
    names = [p["display_name"] for p in resp.json()["players"] if not p["is_host"]]
    assert names == ["Peťo"]


@pytest.mark.asyncio
async def test_room_is_full_at_the_player_cap(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    for i in range(MAX_PLAYERS - 1):
        ok = await client.post(
            "/api/v1/rooms/join",
            json={"display_name": f"G{i}", "join_token": room["join_token"]},
            headers=_h(f"g{i}", OTHER_V4),
        )
        assert ok.status_code == 200
    full = await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "late", "join_token": room["join_token"]},
        headers=_h("late", OTHER_V4),
    )
    assert full.status_code == 409


@pytest.mark.asyncio
async def test_a_started_game_leaves_the_nearby_list(ctx):
    client, sessions, service = ctx
    room = await _host_room(client, sessions)
    stored = await service.store.get(room["room_id"], service_now())
    session = await sessions.get_session(stored.session_id)
    session.transition(SessionPhase.ASKING)
    await sessions.update_session(session)
    assert await _nearby(client, "guest", HOME_V4) == []


def service_now():
    from datetime import datetime, timezone

    return datetime.now(timezone.utc)


@pytest.mark.asyncio
async def test_state_is_members_only_and_cheap_when_nothing_changed(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    url = f"/api/v1/rooms/{room['room_id']}/state"
    assert (await client.get(url, headers=_h("stranger", HOME_V4))).status_code == 404
    first = (await client.get(url, headers=_h("host", HOME_V4))).json()
    assert first["changed"] and first["is_host"]
    same = await client.get(
        url, params={"since": first["version"]}, headers=_h("host", HOME_V4)
    )
    assert same.json() == {
        "room_id": room["room_id"],
        "version": first["version"],
        "changed": False,
    }
    await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "Jana", "join_token": room["join_token"]},
        headers=_h("jana", OTHER_V4),
    )
    moved = await client.get(
        url, params={"since": first["version"]}, headers=_h("host", HOME_V4)
    )
    assert moved.json()["changed"] and len(moved.json()["players"]) == 2


@pytest.mark.asyncio
async def test_only_the_host_removes_others_and_nobody_removes_the_host(ctx):
    client, sessions, _ = ctx
    room = await _host_room(client, sessions)
    ids = {}
    for name in ("jana", "peto"):
        resp = await client.post(
            "/api/v1/rooms/join",
            json={"display_name": name, "join_token": room["join_token"]},
            headers=_h(name, OTHER_V4),
        )
        ids[name] = resp.json()["you"]
        players = resp.json()["players"]
    host_id = next(p["participant_id"] for p in players if p["is_host"])
    base = f"/api/v1/rooms/{room['room_id']}/players"
    assert (
        await client.delete(f"{base}/{ids['peto']}", headers=_h("jana", HOME_V4))
    ).status_code == 403
    assert (
        await client.delete(f"{base}/{host_id}", headers=_h("jana", HOME_V4))
    ).status_code == 403
    assert (
        await client.delete(f"{base}/{ids['peto']}", headers=_h("host", HOME_V4))
    ).status_code == 204
    assert (
        await client.delete(f"{base}/{ids['jana']}", headers=_h("jana", HOME_V4))
    ).status_code == 204  # a guest may leave
    state = await client.get(
        f"/api/v1/rooms/{room['room_id']}/state", headers=_h("host", HOME_V4)
    )
    assert [p["display_name"] for p in state.json()["players"]] == ["Michal"]


@pytest.mark.asyncio
async def test_a_guest_deleting_their_account_does_not_end_the_hosts_game(ctx):
    client, sessions, service = ctx
    room = await _host_room(client, sessions)
    await client.post(
        "/api/v1/rooms/join",
        json={"display_name": "Jana", "join_token": room["join_token"]},
        headers=_h("jana", OTHER_V4),
    )
    await sessions.forget_user("jana")
    state = await client.get(
        f"/api/v1/rooms/{room['room_id']}/state", headers=_h("host", HOME_V4)
    )
    assert state.status_code == 200
    assert [p["display_name"] for p in state.json()["players"]] == ["Michal"]


@pytest.mark.asyncio
async def test_the_host_deleting_their_account_ends_the_game(ctx):
    client, sessions, service = ctx
    room = await _host_room(client, sessions)
    await sessions.forget_user("host")
    await service.store.forget_host("host")
    assert await _nearby(client, "guest", HOME_V4) == []
    state = await client.get(
        f"/api/v1/rooms/{room['room_id']}/state", headers=_h("host", HOME_V4)
    )
    assert state.status_code == 404


@pytest.mark.asyncio
async def test_postgres_store_finds_by_network_and_token_and_forgets_the_host(
    db_sessionmaker,
):
    from datetime import datetime, timedelta, timezone

    from app.rooms.store import PostgresRoomStore, Room

    store = PostgresRoomStore(db_sessionmaker)
    now = datetime.now(timezone.utc)
    room = Room(
        room_id="r_pg1",
        session_id="sess_pg1",
        host_subject_id="host-pg",
        join_token="tok-pg1",
        net_v4=f"v4:{HOME_V4}",
        net_v6=network_key(HOME_V6_HOST),
        created_at=now,
        expires_at=now + timedelta(hours=1),
    )
    await store.insert(room)
    window = now - timedelta(minutes=30)
    assert [
        r.room_id for r in await store.nearby([network_key(HOME_V6_GUEST)], window, now)
    ] == ["r_pg1"]
    assert await store.nearby([f"v4:{OTHER_V4}"], window, now) == []
    assert (
        await store.nearby([network_key(HOME_V4)], now + timedelta(seconds=1), now)
        == []
    )
    assert (await store.by_token("tok-pg1", now)).session_id == "sess_pg1"
    assert await store.get("r_pg1", now + timedelta(hours=2)) is None  # expired
    assert await store.forget_host("host-pg") == 1
    assert await store.get("r_pg1", now) is None
