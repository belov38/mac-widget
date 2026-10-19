"""Pure functions that turn `tailscale` CLI output into the topology JSON."""
from __future__ import annotations

import ipaddress
import re
import statistics
from datetime import datetime, timezone

SCHEMA = 1

# Matches lines like "pong from pve (100.x.y.z) via 192.168.1.116:41641 in 3ms".
_PONG = re.compile(r"^pong from \S+ \([^)]*\) via (?P<via>.+?) in (?P<val>[\d.]+)(?P<unit>ms|s|µs|us)\s*$")
_DERP = re.compile(r"^DERP\((?P<region>[^)]+)\)$")
_UNITS = {"s": 1000.0, "ms": 1.0, "µs": 0.001, "us": 0.001}


def node_name(peer: dict) -> str:
    """Short MagicDNS name ("ws-win"); HostName can be "localhost" or duplicated."""
    dns = (peer.get("DNSName") or "").rstrip(".")
    return dns.split(".")[0] if dns else peer.get("HostName", "?")


def _ts(value: str | None) -> str | None:
    """Tailscale timestamps use year 1 for "never"; map that to None."""
    if not value or value.startswith("0001-"):
        return None
    return value


def classify(via: str) -> dict:
    """Path kind from the "via ..." part of a pong line."""
    m = _DERP.match(via)
    if m:
        return {"kind": "derp", "via": m.group("region")}
    if via.lower().startswith("peer-relay"):
        return {"kind": "peer_relay", "via": via}
    host = via.rsplit(":", 1)[0].strip("[]")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return {"kind": "direct", "via": via}
    local = ip.is_private or ip.is_link_local
    return {"kind": "lan" if local else "direct", "via": via}


def parse_ping(output: str) -> list[dict]:
    """All pongs in order, each with kind, via and latency in ms."""
    pongs = []
    for line in output.splitlines():
        m = _PONG.match(line.strip())
        if not m:
            continue
        p = classify(m.group("via"))
        p["ms"] = round(float(m.group("val")) * _UNITS[m.group("unit")], 1)
        pongs.append(p)
    return pongs


def path_from_pongs(pongs: list[dict]) -> dict | None:
    """Final path with median/min/max latency over the pongs on that path.

    The first pong on the final path is skipped when the link switched to it
    during the run (it carries the path setup cost). The first pong's path is
    kept when it differs (often DERP while the link warms up).
    """
    if not pongs:
        return None
    last = pongs[-1]
    key = (last["kind"], last["via"])
    same = [p for p in pongs if (p["kind"], p["via"]) == key]
    switched = (pongs[0]["kind"], pongs[0]["via"]) != key
    if switched and len(same) > 1:
        same = same[1:]
    ms = sorted(p["ms"] for p in same)
    path = {
        "kind": last["kind"],
        "via": last["via"],
        "ms": round(statistics.median(ms), 1),
        "minMs": ms[0],
        "maxMs": ms[-1],
        "n": len(ms),
    }
    if switched:
        first = pongs[0]
        path["first"] = {"kind": first["kind"], "via": first["via"], "ms": first["ms"]}
    return path


def own_peers(status: dict, hidden: frozenset = frozenset()) -> list[dict]:
    """Peers owned by the same user as this node; shared, foreign and hidden nodes are dropped."""
    uid = status["Self"]["UserID"]
    return [p for p in (status.get("Peer") or {}).values()
            if p.get("UserID") == uid and node_name(p) not in hidden]


def netcheck_summary(netcheck: dict | None, derp_codes: dict) -> dict:
    if not netcheck:
        return {}
    pref = str(netcheck.get("PreferredDERP", ""))
    lat_ns = (netcheck.get("RegionLatency") or {}).get(pref)
    return {
        "udp": bool(netcheck.get("UDP")),
        "ipv6": bool(netcheck.get("IPv6")),
        "hardNat": bool(netcheck.get("MappingVariesByDestIP")),
        "preferredDerp": derp_codes.get(pref, pref) or None,
        "derpMs": round(lat_ns / 1e6, 1) if lat_ns else None,
        "publicAddr": netcheck.get("GlobalV4") or None,
    }


def build(status: dict, pings: dict, netcheck: dict | None, derp_codes: dict,
          pve_guests: set, now: datetime | None = None,
          hidden: frozenset = frozenset()) -> dict:
    """Topology document. `pings` maps peer ID to raw `tailscale ping` output (or None if skipped)."""
    now = now or datetime.now(timezone.utc)
    me = status["Self"]
    lan = [a.rsplit(":", 1)[0] for a in me.get("Addrs") or []
           if classify(a)["kind"] == "lan"]
    nodes = []
    for p in own_peers(status, hidden):
        name = node_name(p)
        raw = pings.get(p["ID"])
        path = path_from_pongs(parse_ping(raw)) if raw else None
        node = {
            "id": p["ID"],
            "name": name,
            "os": p.get("OS", ""),
            "online": bool(p.get("Online")),
            "lastSeen": _ts(p.get("LastSeen")),
            "derp": p.get("Relay") or None,
            "ip": (p.get("TailscaleIPs") or [None])[0],
            "parent": "pve" if name in pve_guests else None,
            "exitNode": bool(p.get("ExitNode")),
            "path": path,
        }
        if p.get("Online") and path is None:
            node["error"] = "no pong"
        nodes.append(node)
    nodes.sort(key=lambda n: n["name"])
    return {
        "schema": SCHEMA,
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "self": {
            "name": node_name(me),
            "os": me.get("OS", ""),
            "derp": me.get("Relay") or None,
            "lan": lan,
            **netcheck_summary(netcheck, derp_codes),
        },
        "nodes": nodes,
    }
