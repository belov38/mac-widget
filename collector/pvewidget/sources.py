"""Raw data collection from pvesh and lm-sensors."""
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor

NODE = "pve"
CALL_TIMEOUT = 10.0
FSINFO_TIMEOUT = 5.0


def run_cmd(argv, timeout):
    """Run a command and return stdout; raises on failure or timeout."""
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       timeout=timeout, check=True, text=True)
    return p.stdout


def _pvesh(runner, path, timeout=CALL_TIMEOUT, extra=()):
    argv = ["pvesh", "get", path, "--output-format", "json", *extra]
    return json.loads(runner(argv, timeout))


def _rrd(runner, path, period, cf):
    try:
        return _pvesh(runner, path, extra=["--timeframe", period, "--cf", cf]) or []
    except Exception:
        return []


def read_file(path):
    with open(path) as f:
        return f.read()


def _guest_cgroup(typ, vmid):
    if typ == "qemu":
        return f"/sys/fs/cgroup/qemu.slice/{vmid}.scope"
    return f"/sys/fs/cgroup/lxc/{vmid}"


def _optional(fn):
    try:
        return fn()
    except Exception:
        return None


def collect(period, runner=run_cmd, reader=read_file):
    """Collect the raw dict consumed by build.build_snapshot."""
    def psi(base, kinds):
        return {k: _optional(lambda k=k: reader(f"{base}/{k}.pressure" if base else f"/proc/pressure/{k}"))
                for k in kinds}

    status = _pvesh(runner, f"/nodes/{NODE}/status")
    resources = _pvesh(runner, "/cluster/resources")
    guests_res = [r for r in resources
                  if r.get("type") in ("qemu", "lxc") and r.get("template") != 1]

    with ThreadPoolExecutor(max_workers=8) as pool:
        node_avg = pool.submit(_rrd, runner, f"/nodes/{NODE}/rrddata", period, "AVERAGE")
        node_max = pool.submit(_rrd, runner, f"/nodes/{NODE}/rrddata", period, "MAX")
        sensors = pool.submit(_optional, lambda: json.loads(runner(["sensors", "-j"], CALL_TIMEOUT)))
        guest_futs = {}
        for r in guests_res:
            vmid, typ = r["vmid"], r["type"]
            base = f"/nodes/{NODE}/{typ}/{vmid}"
            fs = None
            if typ == "qemu" and r.get("status") == "running":
                fs = pool.submit(_optional, lambda b=base: _pvesh(
                    runner, f"{b}/agent/get-fsinfo", timeout=FSINFO_TIMEOUT))
            guest_futs[vmid] = (
                pool.submit(_rrd, runner, f"{base}/rrddata", period, "AVERAGE"),
                pool.submit(_rrd, runner, f"{base}/rrddata", period, "MAX"),
                fs,
            )
        guests = {
            vmid: {"rrd_avg": a.result(), "rrd_max": m.result(),
                   "fsinfo": f.result() if f else None}
            for vmid, (a, m, f) in guest_futs.items()
        }
        for r in guests_res:
            if r.get("status") == "running":
                guests[r["vmid"]]["psi"] = psi(_guest_cgroup(r["type"], r["vmid"]), ("cpu", "memory"))
        return {
            "status": status,
            "resources": resources,
            "sensors": sensors.result(),
            "node_rrd_avg": node_avg.result(),
            "node_rrd_max": node_max.result(),
            "psi": psi(None, ("cpu", "memory", "io")),
            "guests": guests,
        }
