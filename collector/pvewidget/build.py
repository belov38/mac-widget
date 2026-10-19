"""Pure functions turning raw pve data into parts of the snapshot."""
import bisect

from . import config

# PSI values come in percent; the snapshot keeps every ratio in 0...1.
PSI_SCALE = 0.01


def _reading(chip_data, chip):
    feature = chip_data.get(config.SENSOR_FEATURES.get(chip, config.DEFAULT_FEATURE))
    if not isinstance(feature, dict):
        return None
    suffix = "_input"
    for key, val in feature.items():
        if key.endswith(suffix):
            prefix = key[: -len(suffix)]
            return val, feature.get(prefix + "_max"), feature.get(prefix + "_crit")
    return None


def build_temps(sensors):
    """Build temperature items from `sensors -j` output, in SENSOR_LABELS order."""
    if not sensors:
        return []
    items = []
    for chip, (sid, label) in config.SENSOR_LABELS.items():
        chip_data = sensors.get(chip)
        if not isinstance(chip_data, dict):
            continue
        r = _reading(chip_data, chip)
        if r is None:
            continue
        value, t_max, t_crit = r
        if chip == "coretemp-isa-0000":
            warn, crit = config.CPU_TEMP
        else:
            if t_max is None and t_crit is None:
                continue
            warn = t_max if t_max is not None else t_crit
            crit = t_crit if t_crit is not None else warn
            if warn >= crit:
                warn = crit - 10
        items.append({"id": sid, "label": label, "value": value, "warn": warn, "crit": crit})
    return items


def build_storages(resources):
    """Build storage usage items for configured storages, in config order."""
    by_name = {r["storage"]: r for r in resources if r.get("type") == "storage"}
    items = []
    for name, label in config.STORAGES:
        r = by_name.get(name)
        if r is None or "disk" not in r or "maxdisk" not in r:
            continue
        items.append({"id": name, "label": label, "used": r["disk"], "total": r["maxdisk"]})
    return items


def build_host_now(status, resources):
    """Build the instantaneous host values from node status and cluster resources."""
    node = next((r for r in resources if r.get("type") == "node"), {})
    mem = status["memory"]
    swap = status["swap"]
    return {
        "name": node.get("node", "pve"),
        "uptime_s": status["uptime"],
        "cpus": status["cpuinfo"]["cpus"],
        "load": [float(x) for x in status["loadavg"]],
        "cpu_now": node.get("cpu", status.get("cpu", 0.0)),
        "mem_used": mem["used"],
        "mem_total": mem["total"],
        "swap_used": swap["used"],
        "swap_total": swap["total"],
    }


def _points(rows, key, denom_key=None, scale=1.0):
    pts = []
    for row in rows or []:
        t, v = row.get("time"), row.get(key)
        if t is None or v is None:
            continue
        if denom_key is not None:
            d = row.get(denom_key)
            if not d:
                continue
            v = v / d
        pts.append((t, v * scale))
    return pts


def _bucket_index(ends, t):
    i = bisect.bisect_left(ends, t)
    return i if i < len(ends) else None


def series(rows, key, max_points=96, denom_key=None, max_rows=None, pressure_key=None):
    """Return [[time, avg, max]] points in at most max_points buckets.

    avg is the mean of the bucket's AVERAGE rows. max is the max of the MAX rows whose
    time falls into the bucket, (previous bucket end, bucket end]; it falls back to avg
    when the bucket has no MAX rows and is never below avg.

    With pressure_key, buckets that have pressure data get two more values,
    [time, avg, max, pressure avg, pressure max], built the same way and scaled from
    percent to 0...1.
    """
    pts = _points(rows, key, denom_key)
    n = len(pts)
    buckets = min(n, max_points)
    chunks = [pts[i * n // buckets:(i + 1) * n // buckets] for i in range(buckets)]
    ends = [c[-1][0] for c in chunks]
    peaks = [None] * buckets
    for t, v in _points(max_rows, key, denom_key):
        i = _bucket_index(ends, t)
        if i is not None and (peaks[i] is None or v > peaks[i]):
            peaks[i] = v
    p_sums, p_counts, p_peaks = [0.0] * buckets, [0] * buckets, [None] * buckets
    if pressure_key is not None:
        for t, v in _points(rows, pressure_key, scale=PSI_SCALE):
            i = _bucket_index(ends, t)
            if i is not None:
                p_sums[i] += v
                p_counts[i] += 1
        for t, v in _points(max_rows, pressure_key, scale=PSI_SCALE):
            i = _bucket_index(ends, t)
            if i is not None and (p_peaks[i] is None or v > p_peaks[i]):
                p_peaks[i] = v
    out = []
    for i, (chunk, end, peak) in enumerate(zip(chunks, ends, peaks)):
        avg = sum(v for _, v in chunk) / len(chunk)
        point = [end, avg, avg if peak is None else max(peak, avg)]
        if p_counts[i]:
            p_avg = p_sums[i] / p_counts[i]
            point += [p_avg, p_avg if p_peaks[i] is None else max(p_peaks[i], p_avg)]
        out.append(point)
    return out


def stats(avg_rows, max_rows, key, denom_key=None, scale=1.0):
    """Return (mean over AVERAGE rows, max over MAX rows); None when no data."""
    avg = [v for _, v in _points(avg_rows, key, denom_key, scale)]
    peak = [v for _, v in _points(max_rows, key, denom_key, scale)]
    return (sum(avg) / len(avg) if avg else None, max(peak) if peak else None)


def parse_psi(text, line="some"):
    """Return avg60 of a PSI file line ("some" or "full") as 0...1; None when missing."""
    for row in (text or "").splitlines():
        parts = row.split()
        if not parts or parts[0] != line:
            continue
        for field in parts[1:]:
            name, _, value = field.partition("=")
            if name == "avg60":
                try:
                    return float(value) * PSI_SCALE
                except ValueError:
                    return None
    return None


def pressure(avg_rows, max_rows, key, now):
    """Pressure summary: now from the live PSI file, avg/peak over the period."""
    avg, peak = stats(avg_rows, max_rows, key, scale=PSI_SCALE)
    return {"now": now, "avg": avg, "peak": peak}


def pick_disk_from_fsinfo(fsinfo):
    """Pick the largest filesystem from a guest-agent get-fsinfo reply."""
    result = (fsinfo or {}).get("result")
    if not isinstance(result, list):
        return None
    best = None
    for fs in result:
        if "total-bytes" not in fs or "used-bytes" not in fs:
            continue
        if best is None or fs["total-bytes"] > best["total-bytes"]:
            best = fs
    if best is None:
        return None
    return {"used": best["used-bytes"], "total": best["total-bytes"], "mount": best.get("mountpoint", "")}


def _metric(now, avg_rows, max_rows, key, denom_key=None, pressure_key=None, pressure_now=None):
    avg, peak = stats(avg_rows, max_rows, key, denom_key)
    out = {"now": now, "avg": avg, "peak": peak,
           "series": series(avg_rows, key, denom_key=denom_key, max_rows=max_rows, pressure_key=pressure_key)}
    if pressure_key is not None:
        out["pressure"] = pressure(avg_rows, max_rows, pressure_key, pressure_now)
    return out


def build_guest(res, rrd_avg, rrd_max, disk, psi=None):
    """Build one guest object. psi holds the raw cgroup cpu/memory pressure files."""
    psi = psi or {}
    if res.get("type") == "lxc":
        if res.get("maxdisk"):
            disk = {"used": res["disk"], "total": res["maxdisk"], "mount": "/"}
        else:
            disk = None
    elif res.get("status") != "running":
        disk = None
    return {
        "vmid": res["vmid"],
        "type": res["type"],
        "name": res.get("name") or f"{res['type']} {res['vmid']}",
        "status": res.get("status", "unknown"),
        "cpus": res.get("maxcpu") or 0,
        "cpu": _metric(res.get("cpu") or 0.0, rrd_avg, rrd_max, "cpu",
                       pressure_key="pressurecpusome", pressure_now=parse_psi(psi.get("cpu"))),
        "mem": {"used": res.get("mem") or 0, "total": res.get("maxmem") or 0},
        "mem_pressure": parse_psi(psi.get("memory"), "full"),
        "disk": disk,
    }


def build_snapshot(period, now, raw):
    """Assemble the full snapshot from raw pve data."""
    h = build_host_now(raw["status"], raw["resources"])
    avg_rows, max_rows = raw.get("node_rrd_avg"), raw.get("node_rrd_max")
    psi = raw.get("psi") or {}
    mem = _metric(None, avg_rows, max_rows, "memused", "memtotal", pressure_key="pressurememoryfull",
                  pressure_now=parse_psi(psi.get("memory"), "full"))
    mem.pop("now")
    mem = {"used": h["mem_used"], "total": h["mem_total"], **mem}
    host = {
        "name": h["name"],
        "uptime_s": h["uptime_s"],
        "cpus": h["cpus"],
        "load": h["load"],
        "cpu": _metric(h["cpu_now"], avg_rows, max_rows, "cpu", pressure_key="pressurecpusome",
                       pressure_now=parse_psi(psi.get("cpu"))),
        "mem": mem,
        "io_pressure": pressure(avg_rows, max_rows, "pressureiosome", parse_psi(psi.get("io"))),
        "swap": {"used": h["swap_used"], "total": h["swap_total"]},
        "temps": build_temps(raw.get("sensors")),
        "storages": build_storages(raw["resources"]),
    }
    guests = []
    extra = raw.get("guests") or {}
    for res in raw["resources"]:
        if res.get("type") not in ("qemu", "lxc") or res.get("template") == 1:
            continue
        g = extra.get(res["vmid"], {})
        disk = pick_disk_from_fsinfo(g["fsinfo"]) if g.get("fsinfo") else None
        guests.append(build_guest(res, g.get("rrd_avg", []), g.get("rrd_max", []), disk, g.get("psi")))
    guests.sort(key=lambda x: x["vmid"])
    return {"schema": 1, "generated_at": now, "period": period, "host": host, "guests": guests}
