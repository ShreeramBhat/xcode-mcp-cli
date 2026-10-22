#!/usr/bin/env python3
"""xc - command-line front end for Xcode's MCP tools (xcrun mcpbridge).

Every tool Xcode exposes over MCP becomes a subcommand. Flags are generated
from the tool's input schema, so new tools in future Xcode builds show up
without changes here.

  xc tools                          list tools
  xc help build                     show a tool's flags
  xc workspaces                     XcodeListWorkspaces
  xc open MyApp.xcodeproj           XcodeOpenWorkspace (path made absolute)
  xc build                          BuildProject in the workspace found from cwd
  xc grep 'TODO' --output-mode content --show-line-numbers
  xc run-some-tests --tests '{"targetName":"AppTests","testIdentifier":"AppTests/testFoo()"}'
  xc build-project --json | jq .errors

Workspace: tools that take workspaceIdentifier get -w/--workspace, else
$XC_WORKSPACE, else the nearest .xcworkspace/.xcodeproj above the cwd.

Connection: the first call starts a background daemon that keeps one
mcpbridge session open for the calling agent (the nearest non-shell
ancestor process), so later calls skip the bridge startup and handshake.
It exits after $XC_IDLE_TIMEOUT seconds idle (default 600), when that agent
exits, or when mcpbridge does. --no-daemon / XC_NO_DAEMON=1 connects directly.
"""

import argparse
try:
    import ctypes
except ImportError:
    ctypes = None
import fcntl
import hashlib
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

VERSION = "1.0"
PROTOCOL_VERSION = "2025-06-18"
CACHE_DIR = os.path.join(os.path.expanduser("~/Library/Caches"), "xc")
RUN_DIR = os.path.join(CACHE_DIR, "run")
DEFAULT_IDLE_TIMEOUT = 600

# Processes skipped when looking for the agent that owns a daemon.
WRAPPER_COMMANDS = {"sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "env", "xcrun", "sudo",
                    "login", "nohup", "time", "timeout", "gtimeout", "xargs", "script", "caffeinate", "xc"}
# Environment that selects which Xcode the bridge talks to; part of the daemon key.
BRIDGE_ENV = ("MCP_XCODE_PID", "MCP_XCODE_SESSION_ID", "DEVELOPER_DIR")

SHORT_ALIASES = {
    "build": "BuildProject",
    "run": "RunProject",
    "stop": "StopProject",
    "test": "RunAllTests",
    "tests": "GetTestList",
    "docs": "DocumentationSearch",
    "log": "GetBuildLog",
    "console": "GetConsoleOutput",
    "lldb": "InvokeDebuggerCommand",
    "preview": "RenderPreview",
    "snippet": "RunCodeSnippet",
    "destinations": "XcodeListRunDestinations",
    "destination": "XcodeSwitchRunDestination",
    "scheme": "XcodeSwitchScheme",
    "close": "XcodeCloseWorkspace",
    "edit": "XcodeUpdate",
    "open": "XcodeOpenWorkspace",
    "workspaces": "XcodeListWorkspaces",
    "schemes": "XcodeListSchemes",
    "targets": "XcodeListTargets",
    "templates": "XcodeListTemplates",
    "test-plans": "XcodeListTestPlans",
    "mkdir": "XcodeMakeDir",
    "issues": "XcodeRefreshCodeIssuesInFile",
    "settings": "GetTargetBuildSettings",
    "device-session": "DeviceInteractionStartWorkspaceSession",
    "device-run": "DeviceInteractionInstallAndRun",
    "device-input": "DeviceInteractionSynthesize",
    "device-end": "DeviceInteractionEndSession",
}

# `xcrun mcp-server` management commands. These need root; xc adds sudo.
SERVER_SUDO_COMMANDS = {"enable", "disable", "approve", "allow-folder", "clear-permissions", "reset-all", "deny"}
# Top-level shortcuts for server commands whose names don't clash with tool aliases.
SERVER_SHORTCUTS = {"status": "status", "approve": "approve", "deny": "deny",
                    "allow-folder": "allow-folder", "logs": "show-logs"}

NOT_APPROVED_HINT = """
xc: Xcode hasn't approved this agent yet. Either:
  xc open /path/to/App.xcodeproj         # Xcode shows an approval prompt
or approve from the terminal:
  xc status                              # find the pending request id
  xc approve <id> --always               # runs sudo xcrun mcp-server approve"""

# Where each agent looks for personal Agent Skills (SKILL.md folders), keyed by agent.
SKILL_NAME = "xcode-cli"
SKILL_TARGETS = {
    "claude": "~/.claude/skills",    # Claude Code (Copilot reads it too)
    "copilot": "~/.copilot/skills",  # GitHub Copilot CLI
    "codex": "~/.codex/skills",      # OpenAI Codex
    "cursor": "~/.cursor/skills",    # Cursor
    "agents": "~/.agents/skills",    # shared location read by Codex, Copilot, OpenCode and others
}

# Path-valued arguments that are resolved against the cwd before sending.
ABSPATH_ARGS = {
    ("XcodeOpenWorkspace", "path"),
    ("XcodeNewProject", "destinationPath"),
}


class UsageError(Exception):
    pass


def kebab(name):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "-", name).lower()


# ---------------------------------------------------------------- MCP client

class Bridge:
    """JSON-RPC client over newline-delimited JSON: mcpbridge's pipes or the xc daemon's socket."""

    def __init__(self, reader, write, close, lost_message):
        self._write = write
        self._close = close
        self.lost_message = lost_message
        self.next_id = 0
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, args=(reader,), daemon=True).start()

    @classmethod
    def direct(cls, verbose=False):
        proc = subprocess.Popen(
            ["xcrun", "mcpbridge"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=None if verbose else subprocess.DEVNULL,
            text=True, bufsize=1,
        )

        def write(text):
            proc.stdin.write(text)
            proc.stdin.flush()

        def close():
            try:
                proc.stdin.close()
                proc.wait(timeout=5)
            except Exception:
                proc.kill()

        return cls(proc.stdout, write, close,
                   "mcpbridge exited unexpectedly (re-run with -v to see its stderr)")

    @classmethod
    def via_socket(cls, sock):
        def close():
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()

        return cls(sock.makefile("r", encoding="utf-8"), lambda text: sock.sendall(text.encode()), close,
                   "lost connection to the xc daemon (see `xc daemon`, or use --no-daemon)")

    def _pump(self, reader):
        try:
            for line in reader:
                self.lines.put(line)
        except (OSError, ValueError):
            pass
        self.lines.put(None)

    def _send(self, msg):
        msg["jsonrpc"] = "2.0"
        try:
            self._write(json.dumps(msg) + "\n")
        except (OSError, ValueError):
            raise UsageError(self.lost_message)

    def notify(self, method, params=None):
        msg = {"method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)

    def request(self, method, params=None, timeout=None, on_progress=None):
        self.next_id += 1
        rid = self.next_id
        msg = {"id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)
        try:
            while True:
                try:
                    line = self.lines.get(timeout=timeout)
                except queue.Empty:
                    self.notify("notifications/cancelled", {"requestId": rid, "reason": "timeout"})
                    raise UsageError("timed out after %ss waiting for %s" % (timeout, method))
                if line is None:
                    raise UsageError(self.lost_message)
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if "method" in m:
                    if "id" in m:  # server -> client request; we offer no client capabilities
                        self._send({"id": m["id"], "error": {"code": -32601, "message": "not supported"}})
                    elif on_progress:
                        on_progress(m)
                    continue
                if m.get("id") != rid:
                    continue
                if "error" in m:
                    e = m["error"]
                    raise UsageError("%s failed: %s" % (method, e.get("message", e)))
                return m.get("result", {})
        except KeyboardInterrupt:
            try:
                self.notify("notifications/cancelled", {"requestId": rid, "reason": "interrupted"})
            except UsageError:
                pass
            raise

    def initialize(self):
        r = self.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "xc", "version": VERSION},
        }, timeout=60)
        self.notify("notifications/initialized")
        return r

    def close(self):
        self._close()


def load_tools(bridge, server_version):
    path = os.path.join(CACHE_DIR, "tools-%s.json" % re.sub(r"[^\w.-]", "_", server_version or "unknown"))
    if server_version:
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError):
            pass
    tools, cursor = [], None
    while True:
        r = bridge.request("tools/list", {"cursor": cursor} if cursor else None, timeout=60)
        tools.extend(r.get("tools", []))
        cursor = r.get("nextCursor")
        if not cursor:
            break
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(path, "w") as f:
            json.dump(tools, f)
    except OSError:
        pass
    return tools


# ---------------------------------------------------------------- daemon

class _BSDInfo(ctypes.Structure if ctypes else object):
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
                ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("ids", ctypes.c_uint32 * 6),
                ("rfu", ctypes.c_uint32), ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
                ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32), ("pjobc", ctypes.c_uint32),
                ("tdev", ctypes.c_uint32), ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
                ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)] if ctypes else []


def proc_info(pid):
    """(ppid, start time, process name) for pid via libproc, or None."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        info = _BSDInfo()
        if libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        name = (info.name or info.comm).decode(errors="replace")
        return info.ppid, "%d.%06d" % (info.start_sec, info.start_usec), name
    except Exception:
        return None


def ps_info(pid):
    out = subprocess.run(["ps", "-o", "ppid=,lstart=,comm=", "-p", str(pid)], capture_output=True, text=True).stdout
    parts = out.split(None, 6)  # ppid, 5 lstart fields, comm (may contain spaces)
    if len(parts) == 7:
        return int(parts[0]), " ".join(parts[1:6]), parts[6].strip()
    return None


def process_info(pid):
    return proc_info(pid) or ps_info(pid)


def find_owner():
    """The nearest ancestor that isn't a shell or wrapper: the agent (or terminal) running xc.

    None when there is no such ancestor (e.g. xc was orphaned to launchd)."""
    pid = os.getppid()
    while pid > 1:
        info = process_info(pid)
        if info is None:
            return None
        ppid, started, comm = info
        name = os.path.basename(comm).lstrip("-")
        if name not in WRAPPER_COMMANDS and not re.match(r"(?i)python[\d.]*$", name):
            return {"pid": pid, "start": started, "comm": comm}
        pid = ppid
    return None


def owner_alive(owner):
    info = process_info(owner["pid"])
    return info is not None and info[1] == owner["start"]


def daemon_key(owner):
    ident = [os.getuid(), owner["pid"], owner["start"], owner["comm"]] + [os.environ.get(k, "") for k in BRIDGE_ENV]
    return hashlib.sha1(json.dumps(ident).encode()).hexdigest()[:16]


def run_path(key, ext):
    return os.path.join(RUN_DIR, key + ext)


def try_connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        return s
    except OSError:
        s.close()
        return None


def connect_daemon(verbose):
    """Connect to this agent's daemon, starting it if needed. Returns a Bridge or None."""
    owner = find_owner()
    if owner is None:
        return None
    key = daemon_key(owner)
    sock_path = run_path(key, ".sock")
    sock = try_connect(sock_path)
    proc = None
    deadline = time.time() + 20
    while sock is None and time.time() < deadline:
        if proc is None or proc.poll() is not None:
            os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
            idle = os.environ.get("XC_IDLE_TIMEOUT", str(DEFAULT_IDLE_TIMEOUT))
            with open(run_path(key, ".log"), "ab") as log:
                proc = subprocess.Popen(
                    [sys.executable, os.path.abspath(__file__), "__daemon", key, json.dumps(owner), idle],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True,
                )
        time.sleep(0.03)
        sock = try_connect(sock_path)
    if sock is None:
        return None
    if verbose:
        print("xc: daemon %s for %s[%d] (log: %s)" % (key, os.path.basename(owner["comm"]), owner["pid"],
                                                     run_path(key, ".log")), file=sys.stderr)
    return Bridge.via_socket(sock)


def open_bridge(argv):
    verbose = "-v" in argv or "--verbose" in argv
    if not ("--no-daemon" in argv or os.environ.get("XC_NO_DAEMON")):
        for _ in range(2):
            bridge = connect_daemon(verbose)
            if bridge is None:
                break
            try:
                return bridge, bridge.initialize()
            except UsageError:  # daemon was shutting down as we connected; start a fresh one
                bridge.close()
        if verbose:
            print("xc: daemon unavailable, connecting directly", file=sys.stderr)
    bridge = Bridge.direct(verbose)
    return bridge, bridge.initialize()


class DaemonClient:
    def __init__(self, sock):
        self.sock = sock
        self.lock = threading.Lock()
        self.ids = {}  # client request id -> daemon request id

    def send(self, msg):
        data = (json.dumps(msg) + "\n").encode()
        with self.lock:
            try:
                self.sock.sendall(data)
            except OSError:
                pass


class Daemon:
    """Holds one mcpbridge session and multiplexes xc clients onto it over a Unix socket."""

    def __init__(self, key, owner, idle_timeout):
        self.key = key
        self.owner = owner
        self.idle_timeout = idle_timeout
        self.sock_path = run_path(key, ".sock")
        self.state = threading.Lock()
        self.bridge_lock = threading.Lock()
        self.pending = {}   # daemon id -> (client, client id)
        self.progress = {}  # daemon progress token -> (client, client token)
        self.clients = set()
        self.next_id = 0
        self.calls = 0
        self.started = time.time()
        self.last_used = time.time()
        self.init_result = None
        self.init_error = None
        self.ready = threading.Event()
        self.closing = False

    def log(self, msg):
        print("%s xc daemon[%d]: %s" % (time.strftime("%H:%M:%S"), os.getpid(), msg), file=sys.stderr, flush=True)

    def serve(self):
        os.makedirs(RUN_DIR, mode=0o700, exist_ok=True)
        self.lock_file = open(run_path(self.key, ".lock"), "w")
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return  # another daemon already serves this key
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old_umask = os.umask(0o077)
        self.listener.bind(self.sock_path)
        os.umask(old_umask)
        self.listener.listen(64)
        signal.signal(signal.SIGTERM, lambda *_: self.shutdown("stopped"))
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        os.chdir("/")

        self.proc = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, bufsize=1)
        with open(run_path(self.key, ".json"), "w") as f:
            json.dump({"pid": os.getpid(), "owner": self.owner, "socket": self.sock_path,
                       "idle_timeout": self.idle_timeout, "started": self.started}, f)
        self.log("serving %s[%d], idle timeout %ss" % (self.owner["comm"], self.owner["pid"], self.idle_timeout))
        threading.Thread(target=self._read_bridge, daemon=True).start()
        threading.Thread(target=self._watch, daemon=True).start()
        self._to_bridge({"id": 0, "method": "initialize", "params": {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
            "clientInfo": {"name": "xc", "version": VERSION}}})

        while True:
            try:
                sock, _ = self.listener.accept()
            except OSError:
                break
            client = DaemonClient(sock)
            with self.state:
                if self.closing:
                    sock.close()
                    continue
                self.clients.add(client)
            threading.Thread(target=self._serve_client, args=(client,), daemon=True).start()

    def _to_bridge(self, msg):
        msg["jsonrpc"] = "2.0"
        with self.bridge_lock:
            try:
                self.proc.stdin.write(json.dumps(msg) + "\n")
                self.proc.stdin.flush()
            except (OSError, ValueError):
                pass

    def _serve_client(self, client):
        try:
            for line in client.sock.makefile("r", encoding="utf-8"):
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                self._handle_client_message(client, m)
        except (OSError, ValueError):
            pass
        with self.state:
            self.clients.discard(client)
            orphaned = [gid for gid, (c, _) in self.pending.items() if c is client]
            for gid in orphaned:
                del self.pending[gid]
            self.progress = {t: v for t, v in self.progress.items() if v[0] is not client}
        for gid in orphaned:
            self._to_bridge({"method": "notifications/cancelled",
                             "params": {"requestId": gid, "reason": "client disconnected"}})
        client.sock.close()

    def _handle_client_message(self, client, m):
        method, cid = m.get("method"), m.get("id")
        if method == "initialize":
            self.ready.wait(60)
            with self.state:
                self.last_used = time.time()
            if self.init_result is not None:
                client.send({"jsonrpc": "2.0", "id": cid, "result": self.init_result})
            else:
                client.send({"jsonrpc": "2.0", "id": cid, "error": {
                    "code": -32000, "message": self.init_error or "mcpbridge did not initialize"}})
        elif method == "xc/status":
            with self.state:
                status = {"pid": os.getpid(), "owner": self.owner, "uptime": time.time() - self.started,
                          "idle_for": time.time() - self.last_used, "idle_timeout": self.idle_timeout,
                          "in_flight": len(self.pending), "calls": self.calls,
                          "server": (self.init_result or {}).get("serverInfo")}
            client.send({"jsonrpc": "2.0", "id": cid, "result": status})
        elif method == "notifications/cancelled":
            params = dict(m.get("params") or {})
            with self.state:
                gid = client.ids.get(params.get("requestId"))
            if gid is not None:
                params["requestId"] = gid
                self._to_bridge({"method": method, "params": params})
        elif method and cid is not None:
            params = m.get("params")
            with self.state:
                self.next_id += 1
                gid = self.next_id
                self.pending[gid] = (client, cid)
                client.ids[cid] = gid
                self.calls += 1
                self.last_used = time.time()
                meta = (params or {}).get("_meta") or {}
                if "progressToken" in meta:
                    token = "xc-%d" % gid
                    self.progress[token] = (client, meta["progressToken"])
                    params = dict(params, _meta=dict(meta, progressToken=token))
            msg = {"id": gid, "method": method}
            if params is not None:
                msg["params"] = params
            self._to_bridge(msg)

    def _read_bridge(self):
        for line in self.proc.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            method = m.get("method")
            if method and "id" in m:
                self._to_bridge({"id": m["id"], "error": {"code": -32601, "message": "not supported"}})
            elif method == "notifications/progress":
                params = m.get("params") or {}
                with self.state:
                    target = self.progress.get(params.get("progressToken"))
                if target:
                    target[0].send(dict(m, params=dict(params, progressToken=target[1])))
            elif method == "notifications/message":
                with self.state:
                    targets = {c for c, _ in self.pending.values()}
                for c in targets:
                    c.send(m)
            elif method == "notifications/tools/list_changed":
                for f in os.listdir(CACHE_DIR):
                    if f.startswith("tools-"):
                        os.remove(os.path.join(CACHE_DIR, f))
            elif method:
                pass
            elif m.get("id") == 0:
                if "result" in m:
                    self.init_result = m["result"]
                    self._to_bridge({"method": "notifications/initialized"})
                else:
                    self.init_error = str((m.get("error") or {}).get("message", m.get("error")))
                self.ready.set()
            else:
                with self.state:
                    entry = self.pending.pop(m.get("id"), None)
                    if entry:
                        entry[0].ids.pop(entry[1], None)
                        self.progress.pop("xc-%s" % m.get("id"), None)
                        self.last_used = time.time()
                if entry:
                    entry[0].send(dict(m, id=entry[1]))
        self.init_error = self.init_error or "mcpbridge exited"
        self.ready.set()
        self.shutdown("mcpbridge exited")

    def _watch(self):
        last_owner_check = 0
        while True:
            time.sleep(1)
            now = time.time()
            with self.state:
                busy = bool(self.pending or self.clients)
                if not busy and now - self.last_used > self.idle_timeout:
                    self.closing = True
            if self.closing:
                self.shutdown("idle for %ss" % self.idle_timeout)
            if not busy and now - last_owner_check > 15:
                last_owner_check = now
                if not owner_alive(self.owner):
                    self.shutdown("owner %s[%d] exited" % (self.owner["comm"], self.owner["pid"]))

    def shutdown(self, reason):
        self.log("shutting down: %s" % reason)
        for path in (self.sock_path, run_path(self.key, ".json")):
            try:
                os.unlink(path)
            except OSError:
                pass
        try:
            self.listener.close()
        except OSError:
            pass
        try:
            self.proc.terminate()
        except Exception:
            pass
        os._exit(0)


def fmt_duration(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % divmod(seconds, 60)
    return "%dh%02dm" % (seconds // 3600, seconds % 3600 // 60)


def cmd_daemon(argv):
    p = argparse.ArgumentParser(prog="xc daemon", description="Show or stop xc's background mcpbridge daemons.")
    p.add_argument("action", nargs="?", choices=["status", "stop"], default="status")
    p.add_argument("--all", action="store_true", help="stop: every daemon, not just this agent's")
    ns = p.parse_args(argv)
    owner = find_owner()
    mine = daemon_key(owner) if owner else None
    infos = []
    for f in sorted(os.listdir(RUN_DIR)) if os.path.isdir(RUN_DIR) else []:
        if f.endswith(".json"):
            try:
                with open(os.path.join(RUN_DIR, f)) as fh:
                    infos.append((f[:-5], json.load(fh)))
            except (OSError, ValueError):
                pass
    if ns.action == "stop":
        stopped = 0
        for key, info in infos:
            if ns.all or key == mine:
                try:
                    os.kill(info["pid"], signal.SIGTERM)
                    stopped += 1
                except OSError:
                    pass
        print("stopped %d daemon(s)" % stopped)
        return 0
    if not infos:
        print("no xc daemons running")
    for key, info in infos:
        sock = try_connect(info["socket"])
        if sock is None:
            print("%s  stale (pid %s not answering)" % (key, info.get("pid")))
            continue
        bridge = Bridge.via_socket(sock)
        try:
            st = bridge.request("xc/status", timeout=5)
        except UsageError:
            print("%s  not responding" % key)
            continue
        finally:
            bridge.close()
        owner = st["owner"]
        print("%s  pid %-6d owner %s[%d]  up %s  idle %s/%s  calls %d  in-flight %d%s" % (
            key, st["pid"], os.path.basename(owner["comm"]), owner["pid"], fmt_duration(st["uptime"]),
            fmt_duration(st["idle_for"]), fmt_duration(st["idle_timeout"]), st["calls"], st["in_flight"],
            "  (this agent)" if key == mine else ""))
    return 0


# ---------------------------------------------------------------- tool lookup

def alias_table(tools):
    table = {}
    for t in tools:
        n = t["name"]
        names = {n.lower(), kebab(n)}
        if n.startswith("Xcode") and len(n) > 5:
            names.add(kebab(n[5:]))
        for a in names:
            table.setdefault(a, n)
    for short, n in SHORT_ALIASES.items():
        table.setdefault(short, n)
    return table


def resolve_tool(tools, name):
    by_name = {t["name"]: t for t in tools}
    target = alias_table(tools).get(name.lower()) or alias_table(tools).get(kebab(name))
    if target in by_name:
        return by_name[target]
    close = [t["name"] for t in tools if name.lower().replace("-", "") in t["name"].lower()]
    hint = (" Did you mean: %s?" % ", ".join(close[:5])) if close else " Run `xc tools`."
    raise UsageError("unknown tool %r.%s" % (name, hint))


def short_aliases_for(tool_name, tools):
    return sorted(a for a, n in alias_table(tools).items() if n == tool_name and a != tool_name.lower())


# ---------------------------------------------------------------- arguments

def find_workspace(start):
    d = os.path.abspath(start)
    while True:
        try:
            entries = sorted(os.listdir(d))
        except OSError:
            entries = []
        ws = [e for e in entries if e.endswith(".xcworkspace")]
        proj = [e for e in entries if e.endswith(".xcodeproj")]
        if ws or proj:
            return os.path.join(d, (ws or proj)[0])
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def parse_json(text, what):
    try:
        return json.loads(text)
    except ValueError as e:
        raise UsageError("%s: invalid JSON (%s)" % (what, e))


def coerce(value, schema, flag):
    t = schema.get("type")
    if t == "integer":
        try:
            return int(value)
        except ValueError:
            raise UsageError("%s expects an integer, got %r" % (flag, value))
    if t == "number":
        try:
            return float(value)
        except ValueError:
            raise UsageError("%s expects a number, got %r" % (flag, value))
    if t == "boolean":
        v = value.lower()
        if v in ("1", "true", "yes", "y", "on"):
            return True
        if v in ("0", "false", "no", "n", "off"):
            return False
        raise UsageError("%s expects true/false, got %r" % (flag, value))
    if t == "object":
        if value.lstrip().startswith("{"):
            return parse_json(value, flag)
        if "=" in value:
            k, v = value.split("=", 1)
            return {k: v}
        raise UsageError("%s expects JSON or key=value, got %r" % (flag, value))
    if t == "array":
        if value.lstrip().startswith("["):
            return parse_json(value, flag)
        return [coerce(value, schema.get("items", {}), flag)]
    if t is None and value.lstrip()[:1] in ("{", "["):
        return parse_json(value, flag)
    if "enum" in schema and value not in schema["enum"]:
        raise UsageError("%s must be one of: %s" % (flag, ", ".join(map(str, schema["enum"]))))
    return value


def add_global_options(p, taken=()):
    """xc's own options. One whose long flag a tool argument already uses becomes --xc-<name>."""
    g = p.add_argument_group("output and connection")

    def opt(short, name, **kw):
        flag = "--xc-" + name if "--" + name in taken else "--" + name
        g.add_argument(*([short, flag] if short else [flag]), dest=kw.pop("dest", name.replace("-", "_")), **kw)

    opt("-w", "workspace", help="workspace identifier or path (default: $XC_WORKSPACE, else found from cwd)")
    opt(None, "args", dest="raw_args", metavar="JSON", help="tool arguments as a JSON object, or - to read stdin")
    opt(None, "json", action="store_true", help="print the structured result as JSON")
    opt(None, "raw", action="store_true", help="print the full MCP result")
    opt("-o", "out-dir", help="where to save image/binary results (default: a temp dir)")
    opt(None, "dry-run", action="store_true", help="print the tool call instead of running it")
    opt(None, "timeout", type=float, help="seconds xc waits for the tool (default: no limit)")
    opt("-q", "quiet", action="store_true", help="hide progress messages")
    opt("-v", "verbose", action="store_true", help="show connection details and mcpbridge stderr")
    opt(None, "no-daemon", action="store_true", help="connect to mcpbridge directly for this call")


def build_tool_parser(tool, tools):
    schema = tool.get("inputSchema", {})
    props = schema.get("properties", {})
    required = schema.get("required", [])
    aliases = short_aliases_for(tool["name"], tools)
    p = argparse.ArgumentParser(
        prog="xc %s" % (aliases[0] if aliases else tool["name"]),
        description=tool.get("description", ""),
        epilog="aliases: %s" % ", ".join(aliases) if aliases else None,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    if required:
        p.add_argument("positional", nargs="*", metavar="|".join(required),
                       help="required values in order: %s (or pass them as flags)" % ", ".join(required))
    else:
        p.set_defaults(positional=[])
    g = p.add_argument_group("tool arguments")
    taken = set()
    for name in sorted(props):
        if name == "workspaceIdentifier":
            continue
        ps = props[name]
        flags = ["--" + kebab(name)]
        if kebab(name) != name:
            flags.append("--" + name)
        taken.update(flags)
        t = ps.get("type")
        help_ = ps.get("description", "")
        if name in required:
            help_ = "[required] " + help_
        if t == "boolean":
            g.add_argument(*flags, dest="t_" + name, action="store_const", const="true",
                           help=help_ + " (use --no-%s or =false to turn off)" % kebab(name))
            g.add_argument("--no-" + kebab(name), dest="t_" + name, action="store_const", const="false",
                           help=argparse.SUPPRESS)
        elif t in ("array", "object"):
            items = ps.get("items", {}).get("type", "")
            meta = {"array": "JSON|VALUE", "object": "JSON|K=V"}[t]
            extra = " (repeatable%s)" % (", items are %s" % items if items else "")
            g.add_argument(*flags, dest="t_" + name, action="append", metavar=meta, help=help_ + extra)
        else:
            choices = ps.get("enum")
            meta = "{%s}" % ",".join(map(str, choices)) if choices else t.upper() if t else "VALUE"
            g.add_argument(*flags, dest="t_" + name, metavar=meta, help=help_)
    add_global_options(p, taken)
    return p


def normalize_bool_flags(tool, argv):
    """Rewrite --flag=false / --flag=true for boolean flags into switches."""
    bools = set()
    for name, ps in tool.get("inputSchema", {}).get("properties", {}).items():
        if ps.get("type") == "boolean":
            bools.update({kebab(name), name})
    out = []
    for a in argv:
        m = re.match(r"--([\w-]+)=(.*)$", a)
        if m and m.group(1) in bools:
            on = coerce(m.group(2), {"type": "boolean"}, "--" + m.group(1))
            out.append("--" + ("" if on else "no-") + kebab(m.group(1)))
        else:
            out.append(a)
    return out


def collect_arguments(tool, ns):
    schema = tool.get("inputSchema", {})
    props = schema.get("properties", {})
    required = schema.get("required", [])
    args = {}
    if ns.raw_args:
        text = sys.stdin.read() if ns.raw_args == "-" else ns.raw_args
        obj = parse_json(text, "--args")
        if not isinstance(obj, dict):
            raise UsageError("--args must be a JSON object")
        args.update(obj)
    for name, ps in props.items():
        val = getattr(ns, "t_" + name, None)
        if val is None:
            continue
        flag = "--" + kebab(name)
        t = ps.get("type")
        if t == "array":
            out = []
            for v in val:
                c = coerce(v, ps, flag)
                out.extend(c if isinstance(c, list) else [c])
            args[name] = out
        elif t == "object":
            out = {}
            for v in val:
                c = coerce(v, ps, flag)
                if not isinstance(c, dict):
                    raise UsageError("%s expects a JSON object" % flag)
                out.update(c)
            args[name] = out
        else:
            args[name] = coerce(val, ps, flag)
    pending = [r for r in required if r not in args]
    if len(ns.positional) > len(pending):
        raise UsageError("too many positional values: %s" % " ".join(ns.positional[len(pending):]))
    for name, val in zip(pending, ns.positional):
        args[name] = coerce(val, props.get(name, {}), name)
    for name in list(args):
        if (tool["name"], name) in ABSPATH_ARGS and isinstance(args[name], str):
            args[name] = os.path.abspath(os.path.expanduser(args[name]))
    if "workspaceIdentifier" in props and "workspaceIdentifier" not in args:
        ws = ns.workspace or os.environ.get("XC_WORKSPACE") or find_workspace(os.getcwd())
        if ws:
            if os.path.exists(os.path.expanduser(ws)):
                ws = os.path.abspath(os.path.expanduser(ws))
            args["workspaceIdentifier"] = ws
    missing = [r for r in required if r not in args]
    if missing:
        raise UsageError("missing required argument(s): %s  (see `xc help %s`)"
                         % (", ".join("--" + kebab(m) for m in missing), tool["name"]))
    return args


# ---------------------------------------------------------------- output

def maybe_json(text):
    s = text.strip()
    if s[:1] in ("{", "["):
        try:
            return json.loads(s)
        except ValueError:
            pass
    return None


def save_blob(data_b64, mime, tool_name, out_dir, n):
    import base64
    ext = {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif",
           "application/pdf": ".pdf"}.get(mime or "", ".bin")
    out_dir = out_dir or os.path.join(tempfile.gettempdir(), "xc")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "%s-%d-%d%s" % (tool_name, os.getpid(), n, ext))
    with open(path, "wb") as f:
        f.write(base64.b64decode(data_b64))
    return path


def print_result(tool, result, ns):
    if ns.raw:
        print(json.dumps(result, indent=2))
        return
    content = result.get("content") or []
    if ns.json:
        if "structuredContent" in result:
            print(json.dumps(result["structuredContent"], indent=2))
            return
        texts = [c.get("text", "") for c in content if c.get("type") == "text"]
        parsed = [maybe_json(t) for t in texts]
        out = [p if p is not None else t for p, t in zip(parsed, texts)]
        print(json.dumps(out[0] if len(out) == 1 else out, indent=2))
        return
    stream = sys.stderr if result.get("isError") else sys.stdout
    for i, c in enumerate(content):
        kind = c.get("type")
        if kind == "text":
            parsed = maybe_json(c.get("text", ""))
            print(json.dumps(parsed, indent=2) if parsed is not None else c.get("text", ""), file=stream)
        elif kind in ("image", "audio"):
            print("saved %s: %s" % (kind, save_blob(c["data"], c.get("mimeType"), tool["name"], ns.out_dir, i)))
        elif kind == "resource":
            r = c.get("resource", {})
            if "text" in r:
                print(r["text"], file=stream)
            elif "blob" in r:
                print("saved resource: %s" % save_blob(r["blob"], r.get("mimeType"), tool["name"], ns.out_dir, i))
            else:
                print(r.get("uri", ""), file=stream)
        elif kind == "resource_link":
            print(c.get("uri", ""), file=stream)
    if not content and "structuredContent" in result:
        print(json.dumps(result["structuredContent"], indent=2))


def progress_printer(quiet):
    def show(m):
        if quiet:
            return
        p = m.get("params") or {}
        if m["method"] == "notifications/progress":
            msg = p.get("message") or ""
            if p.get("total"):
                msg = "[%s/%s] %s" % (p.get("progress"), p["total"], msg)
            if msg:
                print("… " + msg, file=sys.stderr)
        elif m["method"] == "notifications/message":
            data = p.get("data")
            print("… %s" % (data if isinstance(data, str) else json.dumps(data)), file=sys.stderr)
    return show


# ---------------------------------------------------------------- commands

def cmd_tools(tools, argv):
    p = argparse.ArgumentParser(prog="xc tools", description="List Xcode MCP tools.")
    p.add_argument("--json", action="store_true", help="print full tool definitions")
    ns = p.parse_args(argv)
    if ns.json:
        print(json.dumps(tools, indent=2))
        return 0
    rows = []
    for t in sorted(tools, key=lambda t: t["name"]):
        aliases = short_aliases_for(t["name"], tools)
        short = min(aliases, key=len) if aliases else t["name"]
        desc = (t.get("description") or "").strip().split("\n")[0]
        rows.append((short, t["name"], re.split(r"(?<=\.)\s", desc)[0]))
    w1 = max(len(r[0]) for r in rows)
    w2 = max(len(r[1]) for r in rows)
    cols = shutil.get_terminal_size((120, 24)).columns
    for short, name, desc in rows:
        line = "%-*s  %-*s  %s" % (w1, short, w2, name, desc)
        print(line if not sys.stdout.isatty() or len(line) <= cols else line[:cols - 1] + "…")
    return 0


def cmd_server(argv):
    if not argv or argv[0] in ("-h", "--help"):
        return subprocess.call(["xcrun", "mcp-server", "--help"])
    cmd, rest = argv[0], argv[1:]
    if cmd in ("open", "allow-folder"):
        rest = [a if a.startswith("-") else os.path.abspath(os.path.expanduser(a)) for a in rest]
    full = ["xcrun", "mcp-server", cmd] + rest
    if cmd in SERVER_SUDO_COMMANDS and os.geteuid() != 0 and "-h" not in rest and "--help" not in rest:
        full = ["sudo"] + full
    return subprocess.call(full)


def skill_source():
    src = os.path.join(os.path.dirname(os.path.realpath(__file__)), "skills", SKILL_NAME)
    if not os.path.isfile(os.path.join(src, "SKILL.md")):
        raise UsageError("skill files not found next to xc (%s); install xc from a clone of the repo" % src)
    return src


def cmd_skill(argv):
    p = argparse.ArgumentParser(
        prog="xc skill", description="Install the %s Agent Skill so coding agents use xc for Xcode work." % SKILL_NAME,
        epilog="agents: " + ", ".join("%s (%s)" % kv for kv in SKILL_TARGETS.items()))
    p.add_argument("action", choices=["install", "uninstall", "status", "path"])
    p.add_argument("--agent", action="append", choices=sorted(SKILL_TARGETS) + ["all"],
                   help="agent to (un)install for; repeatable (default: every agent whose config folder exists)")
    p.add_argument("--dry-run", action="store_true", help="show what would change")
    ns = p.parse_args(argv)
    if ns.action == "path":
        print(skill_source())
        return 0
    if not ns.agent:
        agents = [a for a, d in SKILL_TARGETS.items() if os.path.isdir(os.path.dirname(os.path.expanduser(d)))]
    elif "all" in ns.agent:
        agents = list(SKILL_TARGETS)
    else:
        agents = ns.agent
    src = skill_source() if ns.action == "install" else None
    for agent in agents:
        dest = os.path.join(os.path.expanduser(SKILL_TARGETS[agent]), SKILL_NAME)
        manifest = os.path.join(dest, "SKILL.md")
        ours = False
        if os.path.isfile(manifest):
            with open(manifest) as f:
                ours = re.search(r"(?m)^name:\s*%s\s*$" % re.escape(SKILL_NAME), f.read()) is not None
        if ns.action == "status":
            print("%-8s %s  %s" % (agent, "installed" if ours else "-", dest))
            continue
        if os.path.exists(dest) and not ours:
            print("%-8s skipped: %s exists and isn't this skill" % (agent, dest), file=sys.stderr)
            continue
        if ns.action == "uninstall":
            if ours and not ns.dry_run:
                shutil.rmtree(dest)
            print("%-8s %s %s" % (agent, "removed" if ours else "not installed", dest))
            continue
        if not ns.dry_run:
            if ours:
                shutil.rmtree(dest)
            shutil.copytree(src, dest, ignore=shutil.ignore_patterns(".DS_Store", "__pycache__"))
        print("%-8s %s %s" % (agent, "updated" if ours else "installed", dest))
    return 0


def usage():
    print(__doc__.strip())
    print("""
Other commands:
  xc tools [--json]                 list tools (cached per Xcode build)
  xc help <tool> | xc schema <tool> flags / raw definition for a tool
  xc refresh                        re-fetch the tool list
  xc server <cmd> [args]            xcrun mcp-server <cmd> (sudo added when needed):
                                    open, stop, enable, disable, approve, allow-folder,
                                    clear-permissions, reset-all, deny, status, show-logs
  xc status [--format json]         agents, folders, pending requests, open workspaces
  xc approve <id> --always          approve a pending agent/folder request (sudo)
  xc allow-folder <dir> --always    pre-permit a folder (sudo)
  xc deny <id> | xc logs
  xc daemon [status | stop [--all]] background connections held for agents
  xc skill install [--agent NAME]   install the xcode-cli Agent Skill for Claude, Copilot,
                                    Codex, Cursor, ~/.agents (also: uninstall, status, path)""")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        usage()
        return 0
    if argv[0] == "--version":
        print("xc %s" % VERSION)
        return 0
    if argv[0] == "server":
        return cmd_server(argv[1:])
    if argv[0] in SERVER_SHORTCUTS:
        return cmd_server([SERVER_SHORTCUTS[argv[0]]] + argv[1:])
    if argv[0] == "daemon":
        return cmd_daemon(argv[1:])
    if argv[0] == "skill":
        return cmd_skill(argv[1:])
    if argv[0] == "refresh":
        for f in os.listdir(CACHE_DIR) if os.path.isdir(CACHE_DIR) else []:
            os.remove(os.path.join(CACHE_DIR, f))
        argv = ["tools"]

    bridge, init = open_bridge(argv)
    argv = [a for a in argv if a != "--no-daemon"]
    try:
        tools = load_tools(bridge, (init.get("serverInfo") or {}).get("version"))
        cmd, rest = argv[0], argv[1:]
        if cmd == "tools":
            return cmd_tools(tools, rest)
        if cmd in ("help", "schema"):
            if not rest:
                raise UsageError("usage: xc %s <tool>" % cmd)
            tool = resolve_tool(tools, rest[0])
            if cmd == "schema":
                print(json.dumps(tool, indent=2))
            else:
                build_tool_parser(tool, tools).print_help()
            return 0
        tool = resolve_tool(tools, cmd)
        ns = build_tool_parser(tool, tools).parse_args(normalize_bool_flags(tool, rest))
        arguments = collect_arguments(tool, ns)
        if ns.dry_run:
            print(json.dumps({"name": tool["name"], "arguments": arguments}, indent=2))
            return 0
        result = bridge.request(
            "tools/call",
            {"name": tool["name"], "arguments": arguments, "_meta": {"progressToken": "xc"}},
            timeout=ns.timeout, on_progress=progress_printer(ns.quiet),
        )
        print_result(tool, result, ns)
        if result.get("isError"):
            text = " ".join(c.get("text", "") for c in result.get("content") or [])
            if "isn't approved" in text and not (ns.json or ns.raw):
                print(NOT_APPROVED_HINT, file=sys.stderr)
            return 1
        return 0
    finally:
        bridge.close()


if __name__ == "__main__":
    if sys.argv[1:2] == ["__daemon"]:
        _, _, key, owner, idle = sys.argv
        Daemon(key, json.loads(owner), float(idle)).serve()
        sys.exit(0)
    try:
        sys.exit(main(sys.argv[1:]))
    except UsageError as e:
        print("xc: %s" % e, file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
