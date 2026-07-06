#!/usr/bin/env python3
"""Shannon driver development — MCP server (no external dependencies).

Wraps the scripts/ helpers as MCP tools for opencode, so the agent can call
typed tools with JSON-schema inputs instead of constructing bash commands.
Speaks MCP stdio: newline-delimited JSON-RPC 2.0.

Each tool delegates to a script in scripts/ (usually with --json) and returns
its stdout as text content. Nonzero exit => isError=true with stderr.

Falls back gracefully: if this server fails to load, the agent can still call
the scripts directly via the bash tool.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(ROOT, "scripts")
PROTOCOL_VERSION = "2024-11-05"


def _schema(props, required=None):
    s = {"type": "object", "properties": props, "additionalProperties": False}
    if required:
        s["required"] = required
    return s


STR = {"type": "string"}
INT = {"type": "integer"}
BOOL = {"type": "boolean"}
STRARR = {"type": "array", "items": {"type": "string"}}

TOOLS = [
    {
        "name": "shannon_list_pci",
        "description": "List Shannon Direct-IO PCIe devices (1cb0:0275) on a remote host. "
                       "Returns JSON: {ok, host, devices:[{bdf, desc}]}.",
        "inputSchema": _schema({"host": STR}, ["host"]),
    },
    {
        "name": "shannon_bind",
        "description": "Bind Shannon PCIe devices to vfio-pci on a remote host (needs root). "
                       "Use all=true (default) or explicit bdfs.",
        "inputSchema": _schema({"host": STR, "all": BOOL, "bdfs": STRARR}, ["host"]),
    },
    {
        "name": "shannon_release_host",
        "description": "Release Shannon devices from the HOST before a QEMU debug session: kill the "
                       "running QEMU tmux session, unmount /dev/df* filesystems (and kill holders), "
                       "unbind devices from the host 'shannon' driver, and rmmod shannon. Run this "
                       "BEFORE shannon_run_qemu / shannon_dev_cycle when the host driver is loaded "
                       "or a previous QEMU session is still up. Returns JSON "
                       "{ok, killed_qemu, unmounted, unbound, rmmod, reset, modules_loaded}.",
        "inputSchema": _schema({"host": STR, "all": BOOL, "bdfs": STRARR, "tmux": STR, "reset": BOOL, "kill_qemu": BOOL}, ["host"]),
    },
    {
        "name": "shannon_fetch_kernel",
        "description": "Ensure vmlinuz-<kver> and/or linux-headers-<kver> are present on the host "
                       "(downloads + unpacks the kernel .deb via temp apt config if missing). "
                       "what: both|image|headers (default both).",
        "inputSchema": _schema({"host": STR, "kver": STR, "what": {"type": "string", "enum": ["both", "image", "headers"]}, "suite": STR}, ["host", "kver"]),
    },
    {
        "name": "shannon_rsync_src",
        "description": "Rsync the driver source from this repo to ~/shannon-src on the host.",
        "inputSchema": _schema({"host": STR, "src": STR}, ["host"]),
    },
    {
        "name": "shannon_build",
        "description": "Build shannon.ko on the host for the given kernel (ensures headers first). "
                       "Returns the path to shannon.ko.",
        "inputSchema": _schema({"host": STR, "kver": STR, "src": STR, "jobs": INT}, ["host", "kver"]),
    },
    {
        "name": "shannon_make_initrd",
        "description": "Pack an initrd with the built shannon.ko + busybox + /init on the host. "
                       "Auto-bootstraps a busybox root if no initrd_template given. "
                       "skip_epilog=false for full epilog recovery (data-integrity runs).",
        "inputSchema": _schema({"host": STR, "kver": STR, "src": STR, "initrd_template": STR, "skip_epilog": BOOL}, ["host", "kver"]),
    },
    {
        "name": "shannon_install_qemu",
        "description": "Install/build QEMU 9.2/10+ on the host (Docker source build matching host "
                       "codename by default; native=true to build without Docker).",
        "inputSchema": _schema({"host": STR, "version": STR, "bundle": STR, "jobs": INT, "native": BOOL}, ["host"]),
    },
    {
        "name": "shannon_run_qemu",
        "description": "Launch QEMU on the host with Shannon device(s) passed through via vfio-pci. "
                       "Returns JSON: {ok, tmux, serial_log, capture_only, kernel, devices}. "
                       "capture_only=true for headless serial-log capture; default is interactive "
                       "in a tmux session with continuous serial logging. "
                       "After launch, use shannon_console(wait_ready) to wait out the 5+ min startup.",
        "inputSchema": _schema({
            "host": STR, "kver": STR, "all": BOOL, "bdfs": STRARR,
            "gdb": BOOL, "tmux": STR, "capture_only": BOOL, "serial_log": STR,
            "memory": STR, "smp": INT, "qemu": STR,
        }, ["host"]),
    },
    {
        "name": "shannon_console",
        "description": "Inspect/drive a running Shannon QEMU guest via its serial log + tmux console. "
                       "action: tail|grep|snapshot|send|send-keys|wait-ready|crash-check. "
                       "wait-ready polls the serial log for 'Probed Direct-IO PCIe Flash' (ready) "
                       "and crash markers; returns JSON {ok, ready, crash, elapsed_s, last_lines}. "
                       "To run validate-integrity INSIDE the guest: action=send, "
                       "cmd='validate-integrity.sh /dev/dfd --json', then action=tail to read the JSON line.",
        "inputSchema": _schema({
            "host": STR, "action": {"type": "string", "enum": ["tail", "grep", "snapshot", "send", "send-keys", "wait-ready", "crash-check"]},
            "tmux": STR, "serial_log": STR, "cmd": STR, "pattern": STR,
            "lines": INT, "timeout": INT, "interval": INT,
        }, ["host", "action"]),
    },
    {
        "name": "shannon_dev_cycle",
        "description": "One-shot end-to-end cycle on the host: fetch kernel -> rsync -> build -> "
                       "pack initrd -> bind vfio-pci -> boot QEMU in tmux. Does NOT wait for the "
                       "device (use shannon_console(wait_ready) next).",
        "inputSchema": _schema({"host": STR, "kver": STR, "all": BOOL, "bdfs": STRARR, "gdb": BOOL, "tmux": STR}, ["host", "kver"]),
    },
]


def run_script(script, args, timeout=1800):
    path = os.path.join(SCRIPTS, script)
    if not os.path.exists(path):
        return {"isError": True, "content": [{"type": "text", "text": f"script not found: {path}"}]}
    try:
        p = subprocess.run(["sh", path] + [str(x) for x in args],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"isError": True, "content": [{"type": "text", "text": f"timeout after {timeout}s"}]}
    out = p.stdout or ""
    err = p.stderr or ""
    if p.returncode != 0:
        text = err or out or f"exit {p.returncode}"
        if out and err:
            text = err + "\n--- stdout ---\n" + out
        return {"isError": True, "content": [{"type": "text", "text": text}]}
    return {"content": [{"type": "text", "text": out}]}


def t_list_pci(a):
    return run_script("shannon-pci-list.sh", ["--host", a["host"], "--json"], 60)


def t_bind(a):
    args = ["--host", a["host"]]
    if a.get("bdfs"):
        args += list(a["bdfs"])
    else:
        args.append("--all")
    return run_script("driver-bind.sh", args, 120)


def t_release_host(a):
    args = ["--host", a["host"]]
    if a.get("bdfs"):
        args += list(a["bdfs"])
    else:
        args.append("--all")
    if a.get("tmux"):
        args += ["--tmux", a["tmux"]]
    if a.get("reset"):
        args.append("--reset")
    if a.get("kill_qemu") is False:
        args.append("--no-kill-qemu")
    args.append("--json")
    return run_script("release-host.sh", args, 300)


def t_fetch_kernel(a):
    args = ["--host", a["host"], "--kernel", a["kver"]]
    what = a.get("what", "both")
    if what == "image":
        args.append("--image-only")
    elif what == "headers":
        args.append("--headers-only")
    if a.get("suite"):
        args += ["--suite", a["suite"]]
    return run_script("fetch-kernel.sh", args, 900)


def t_rsync(a):
    args = ["--host", a["host"]]
    if a.get("src"):
        args += ["--src", a["src"]]
    return run_script("rsync-src.sh", args, 300)


def t_build(a):
    args = ["--host", a["host"], "--kernel", a["kver"]]
    if a.get("src"):
        args += ["--src", a["src"]]
    if a.get("jobs"):
        args += ["-j", str(a["jobs"])]
    return run_script("build-module.sh", args, 1200)


def t_make_initrd(a):
    args = ["--host", a["host"], "--kernel", a["kver"]]
    if a.get("src"):
        args += ["--src", a["src"]]
    if a.get("initrd_template"):
        args += ["--initrd-template", a["initrd_template"]]
    if a.get("skip_epilog") is False:
        args.append("--no-skip-epilog")
    return run_script("make-initrd.sh", args, 900)


def t_install_qemu(a):
    args = ["--host", a["host"], "--version", a.get("version", "9.2.0")]
    if a.get("bundle"):
        args += ["--bundle", a["bundle"]]
    if a.get("native"):
        args.append("--native")
    if a.get("jobs"):
        args += ["-j", str(a["jobs"])]
    return run_script("install-qemu.sh", args, 3600)


def t_run_qemu(a):
    args = ["--host", a["host"], "--json"]
    if a.get("kver"):
        args += ["--kernel", a["kver"]]
    if a.get("memory"):
        args += ["-m", a["memory"]]
    if a.get("smp"):
        args += ["-s", str(a["smp"])]
    if a.get("gdb"):
        args.append("--gdb")
    if a.get("tmux"):
        args += ["--tmux", a["tmux"]]
    if a.get("serial_log"):
        args += ["--serial-log", a["serial_log"]]
    if a.get("capture_only"):
        args.append("--capture-only")
    if a.get("qemu"):
        args += ["--qemu", a["qemu"]]
    if a.get("bdfs"):
        args += list(a["bdfs"])
    else:
        args.append("--all")
    return run_script("qemu-shannon-run.sh", args, 120)


def t_console(a):
    args = ["--host", a["host"], "--json"]
    if a.get("tmux"):
        args += ["--tmux", a["tmux"]]
    if a.get("serial_log"):
        args += ["--serial-log", a["serial_log"]]
    action = a["action"]
    args.append(action)
    if action == "grep" and a.get("pattern"):
        args.append(a["pattern"])
    elif action in ("send", "send-keys") and a.get("cmd"):
        args.append(a["cmd"])
    elif action == "tail":
        if a.get("lines"):
            args += [str(a["lines"])]   # qemu-console tail takes [lines] positionally
    elif action == "wait-ready":
        if a.get("timeout"):
            args += ["--timeout", str(a["timeout"])]
        if a.get("interval"):
            args += ["--interval", str(a["interval"])]
    timeout = 60
    if action == "wait-ready":
        timeout = int(a.get("timeout", 600) or 600) + 30
    return run_script("qemu-console.sh", args, timeout)


def t_dev_cycle(a):
    args = ["--host", a["host"], "--kernel", a["kver"]]
    if a.get("gdb"):
        args.append("--gdb")
    if a.get("tmux"):
        args += ["--tmux", a["tmux"]]
    if a.get("bdfs"):
        args += list(a["bdfs"])
    else:
        args.append("--all")
    return run_script("dev-cycle.sh", args, 1800)


HANDLERS = {
    "shannon_list_pci": t_list_pci,
    "shannon_bind": t_bind,
    "shannon_release_host": t_release_host,
    "shannon_fetch_kernel": t_fetch_kernel,
    "shannon_rsync_src": t_rsync,
    "shannon_build": t_build,
    "shannon_make_initrd": t_make_initrd,
    "shannon_install_qemu": t_install_qemu,
    "shannon_run_qemu": t_run_qemu,
    "shannon_console": t_console,
    "shannon_dev_cycle": t_dev_cycle,
}


def respond(msgid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msgid, "result": result}) + "\n")
    sys.stdout.flush()


def error(msgid, code, message):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msgid,
                                 "error": {"code": code, "message": message}}) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(msg, dict) or "method" not in msg:
            continue
        method = msg["method"]
        params = msg.get("params") or {}
        msgid = msg.get("id")
        if msgid is None:
            # notification (e.g. notifications/initialized) -> no response
            continue
        if method == "initialize":
            respond(msgid, {"protocolVersion": PROTOCOL_VERSION,
                             "capabilities": {"tools": {}},
                             "serverInfo": {"name": "shannon", "version": "1.0.0"}})
        elif method == "tools/list":
            respond(msgid, {"tools": TOOLS})
        elif method == "tools/call":
            name = params.get("name")
            args = params.get("arguments") or {}
            h = HANDLERS.get(name)
            if h is None:
                error(msgid, -32602, f"unknown tool: {name}")
                continue
            try:
                respond(msgid, h(args))
            except Exception as e:  # noqa
                respond(msgid, {"isError": True,
                                "content": [{"type": "text", "text": f"handler error: {e}"}]})
        else:
            error(msgid, -32601, f"method not found: {method}")


if __name__ == "__main__":
    main()
