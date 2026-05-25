import Foundation

public struct GeminiOAuthBridgeStatus: Equatable, Sendable {
    public var isRunning: Bool
    public var hostsInstalled: Bool
    public var portListening: Bool
    public var socksAvailable: Bool
    public var processLine: String?
    public var scriptPath: String
    public var missingDomains: [String]

    public static let empty = GeminiOAuthBridgeStatus(
        isRunning: false,
        hostsInstalled: false,
        portListening: false,
        socksAvailable: false,
        processLine: nil,
        scriptPath: "",
        missingDomains: []
    )

    public var hasPartialState: Bool {
        hostsInstalled || portListening || processLine != nil || !missingDomains.isEmpty
    }

    public var title: String {
        if isRunning { return "运行中" }
        if !socksAvailable { return "Veee SOCKS 未通" }
        if hasPartialState { return "需要修复" }
        return "未运行"
    }

    public var detail: String {
        var parts: [String] = []
        if hostsInstalled {
            parts.append("hosts 已接管")
        } else if processLine != nil || portListening || !missingDomains.isEmpty {
            parts.append("hosts 未接管")
        } else {
            parts.append("hosts 干净")
        }
        if !missingDomains.isEmpty {
            parts.append("缺 \(missingDomains.count) 个接管域名")
        }
        if portListening, processLine != nil, !hostsInstalled {
            parts.append("443 被旧桥占用")
        } else {
            parts.append(portListening ? "443 已监听" : "443 未监听")
        }
        parts.append(socksAvailable ? "Veee SOCKS 可用" : "Veee SOCKS 未通")
        return parts.joined(separator: " · ")
    }
}

public struct GeminiOAuthBridgeManager {
    public static let shared = GeminiOAuthBridgeManager()

    public static let socksHost = "127.0.0.1"
    public static let socksPort = 15235
    public static let listenPort = 443
    public static let domains = [
        "oauth2.googleapis.com",
        "www.googleapis.com",
        "generativelanguage.googleapis.com",
        "accounts.google.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "play.googleapis.com"
    ]

    private static let hostsBegin = "# BEGIN codex-gemini-oauth-bridge"
    private static let helperFileName = "laicai_gemini_oauth_bridge.py"

    public init() {}

    public var scriptURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("LaicaiNative", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("GeminiOAuthBridge", isDirectory: true)
            .appendingPathComponent(Self.helperFileName, isDirectory: false)
    }

    public func status() -> GeminiOAuthBridgeStatus {
        try? ensureHelperScript()
        let hostsText = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        let hostsBlock = Self.hostsBridgeBlock(in: hostsText)
        let missingInBlock = Self.domains.filter { !(hostsBlock ?? "").contains($0) }
        let hostsInstalled = hostsBlock != nil && missingInBlock.isEmpty
        let processLine = firstProcessLine()
        let portListening = shellSucceeds("/usr/bin/nc -z \(Self.socksHost) \(Self.listenPort) >/dev/null 2>&1")
        let socksAvailable = shellSucceeds("/usr/bin/nc -z \(Self.socksHost) \(Self.socksPort) >/dev/null 2>&1")
        let shouldReportMissingDomains = !hostsInstalled && (hostsBlock != nil || portListening || processLine != nil)
        return GeminiOAuthBridgeStatus(
            isRunning: hostsInstalled && portListening && socksAvailable && processLine != nil,
            hostsInstalled: hostsInstalled,
            portListening: portListening,
            socksAvailable: socksAvailable,
            processLine: processLine,
            scriptPath: scriptURL.path,
            missingDomains: shouldReportMissingDomains ? missingInBlock : []
        )
    }

    public func startInTerminal() throws {
        try ensureHelperScript()
        try runWithAdministratorPrivileges(
            command: "cd \(shellQuoted(scriptURL.deletingLastPathComponent().path)) && /usr/bin/env python3 ./\(Self.helperFileName) --repair --daemon"
        )
    }

    public func stopInTerminal() throws {
        try ensureHelperScript()
        try runWithAdministratorPrivileges(
            command: "cd \(shellQuoted(scriptURL.deletingLastPathComponent().path)) && /usr/bin/env python3 ./\(Self.helperFileName) --stop"
        )
    }

    public func revealHelperInFinder() {
        try? ensureHelperScript()
        _ = runProcess(executable: "/usr/bin/open", arguments: ["-R", scriptURL.path])
    }

    private func ensureHelperScript() throws {
        let dir = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        if current != Self.helperScript {
            try Self.helperScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        _ = runProcess(executable: "/bin/chmod", arguments: ["755", scriptURL.path])
    }

    private func runWithAdministratorPrivileges(command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = runProcess(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e", "do shell script \"\(escaped)\" with administrator privileges"
            ]
        )
        if result.exitCode != 0 {
            throw NSError(
                domain: "GeminiOAuthBridge",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "管理员授权失败" : result.output]
            )
        }
    }

    private func firstProcessLine() -> String? {
        let result = runProcess(
            executable: "/bin/bash",
            arguments: ["-lc", "/usr/bin/pgrep -fl 'laicai_gemini_oauth_bridge\\.py|gemini_oauth_bridge\\.py' 2>/dev/null || true"]
        )
        return result.output
            .split(separator: "\n")
            .map(String.init)
            .first { !$0.contains("pgrep -fl") && !$0.contains("bash -lc") && !$0.contains("osascript") }
    }

    private func shellSucceeds(_ command: String) -> Bool {
        runProcess(executable: "/bin/bash", arguments: ["-lc", command]).exitCode == 0
    }

    private static func hostsBridgeBlock(in text: String) -> String? {
        guard let beginRange = text.range(of: hostsBegin) else { return nil }
        let afterBegin = text[beginRange.upperBound...]
        guard let endRange = afterBegin.range(of: "# END codex-gemini-oauth-bridge") else { return nil }
        return String(afterBegin[..<endRange.lowerBound])
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, error.localizedDescription)
        }
    }

    private static let helperScript = #"""
#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import select
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

BRIDGE_VERSION = "2026-05-19.5"
HOSTS = Path("/etc/hosts")
BEGIN = "# BEGIN codex-gemini-oauth-bridge"
END = "# END codex-gemini-oauth-bridge"
PIDFILE = Path("/tmp/laicai-gemini-oauth-bridge.pid")
LOGFILE = Path("/tmp/laicai-gemini-oauth-bridge.log")
LAUNCHD_LABEL = "com.laicai.gemini-oauth-bridge"
LAUNCHD_PLIST = Path("/Library/LaunchDaemons") / f"{LAUNCHD_LABEL}.plist"

DOMAINS = [
    "oauth2.googleapis.com",
    "www.googleapis.com",
    "generativelanguage.googleapis.com",
    "accounts.google.com",
    "cloudcode-pa.googleapis.com",
    "daily-cloudcode-pa.googleapis.com",
    "play.googleapis.com",
]
LISTEN_PORT = 443
SOCKS_HOST = "127.0.0.1"
SOCKS_PORT = 15235
DEFAULT_TARGET = "www.googleapis.com"

stop_event = threading.Event()
listener_sockets = []


def log(message):
    print(message, flush=True)


def require_root():
    if os.geteuid() != 0:
        raise SystemExit("This bridge needs sudo to bind 443 and edit /etc/hosts.")


def flush_dns():
    subprocess.run(["/usr/bin/dscacheutil", "-flushcache"], check=False)
    subprocess.run(["/usr/bin/killall", "-HUP", "mDNSResponder"], check=False)


def strip_block(text):
    lines = text.splitlines()
    out = []
    skipping = False
    for line in lines:
        if line.strip() == BEGIN:
            skipping = True
            continue
        if line.strip() == END:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    return "\n".join(out).rstrip() + "\n"


def install_hosts():
    old = HOSTS.read_text() if HOSTS.exists() else ""
    cleaned = strip_block(old)
    entries = [BEGIN]
    for domain in DOMAINS:
        entries.append(f"127.0.0.1 {domain}")
        entries.append(f"::1 {domain}")
    entries.append(END)
    HOSTS.write_text(cleaned + "\n".join(entries) + "\n")
    flush_dns()
    log("Installed temporary /etc/hosts bridge entries:")
    for domain in DOMAINS:
        log(f"  - {domain}")


def restore_hosts():
    if not HOSTS.exists():
        return
    text = HOSTS.read_text()
    cleaned = strip_block(text)
    if cleaned != text:
        HOSTS.write_text(cleaned)
        flush_dns()
        log("Removed temporary /etc/hosts bridge entries.")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def command_for_pid(pid):
    try:
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "command="], text=True).strip()
    except Exception:
        return ""


def bridge_pids():
    pids = set()
    if PIDFILE.exists():
        try:
            pids.add(int(PIDFILE.read_text().strip()))
        except Exception:
            pass
    for pattern in ("laicai_gemini_oauth_bridge.py", "gemini_oauth_bridge.py"):
        try:
            output = subprocess.check_output(["/usr/bin/pgrep", "-f", pattern], text=True)
            for line in output.splitlines():
                try:
                    pids.add(int(line.strip()))
                except Exception:
                    pass
        except Exception:
            pass
    pids.discard(os.getpid())
    pids.discard(os.getppid())
    alive = []
    for pid in sorted(pids):
        if not pid_alive(pid):
            continue
        command = command_for_pid(pid)
        if not command or "pgrep" in command or "osascript" in command:
            continue
        alive.append(pid)
    return alive


def run_launchctl(args):
    return subprocess.run(
        ["/bin/launchctl", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def unload_launchd_service():
    if LAUNCHD_PLIST.exists():
        for args in (
            ["bootout", f"system/{LAUNCHD_LABEL}"],
            ["bootout", "system", str(LAUNCHD_PLIST)],
        ):
            result = run_launchctl(args)
            if result.returncode == 0:
                log(f"Unloaded launchd service {LAUNCHD_LABEL}.")
                break


def install_launchd_service(script_path):
    LAUNCHD_PLIST.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "Label": LAUNCHD_LABEL,
        "ProgramArguments": [sys.executable, str(script_path), "--foreground"],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "WorkingDirectory": str(script_path.parent),
        "StandardOutPath": str(LOGFILE),
        "StandardErrorPath": str(LOGFILE),
    }
    tmp = LAUNCHD_PLIST.with_suffix(".plist.tmp")
    with tmp.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)
    tmp.replace(LAUNCHD_PLIST)
    os.chmod(LAUNCHD_PLIST, 0o644)
    subprocess.run(["/usr/sbin/chown", "root:wheel", str(LAUNCHD_PLIST)], check=False)

    result = run_launchctl(["bootstrap", "system", str(LAUNCHD_PLIST)])
    if result.returncode != 0 and "already bootstrapped" not in result.stdout.lower():
        raise SystemExit(f"Cannot bootstrap launchd service {LAUNCHD_LABEL}: {result.stdout.strip()}")
    kick = run_launchctl(["kickstart", "-k", f"system/{LAUNCHD_LABEL}"])
    if kick.returncode != 0:
        raise SystemExit(f"Cannot kickstart launchd service {LAUNCHD_LABEL}: {kick.stdout.strip()}")
    log(f"Installed launchd service {LAUNCHD_LABEL} at {LAUNCHD_PLIST}.")


def launchd_state():
    if not LAUNCHD_PLIST.exists():
        return "missing"
    result = run_launchctl(["print", f"system/{LAUNCHD_LABEL}"])
    if result.returncode == 0:
        return "loaded"
    return "plist-present"


def bridge_process_lines():
    return [
        {"pid": pid, "command": command_for_pid(pid)}
        for pid in bridge_pids()
    ]


def pidfile_pid():
    if not PIDFILE.exists():
        return None
    try:
        return int(PIDFILE.read_text().strip())
    except Exception:
        return None


def wait_until_stopped(pids, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        alive = [pid for pid in pids if pid_alive(pid)]
        if not alive:
            return []
        time.sleep(0.1)
    return [pid for pid in pids if pid_alive(pid)]


def stop_existing(unload_launchd=True):
    if unload_launchd:
        unload_launchd_service()

    pids = bridge_pids()
    if not pids:
        restore_hosts()
        try:
            PIDFILE.unlink()
        except FileNotFoundError:
            pass
        return

    for pid in pids:
        try:
            os.kill(pid, signal.SIGINT)
            log(f"Sent SIGINT to bridge pid {pid}.")
        except ProcessLookupError:
            pass
        except PermissionError as exc:
            log(f"Cannot stop pid {pid}: {exc}")

    survivors = wait_until_stopped(pids, 2)
    for pid in survivors:
        if pid_alive(pid):
            try:
                os.kill(pid, signal.SIGTERM)
                log(f"Sent SIGTERM to bridge pid {pid}.")
            except ProcessLookupError:
                pass
            except PermissionError as exc:
                log(f"Cannot terminate pid {pid}: {exc}")

    survivors = wait_until_stopped(survivors, 2)
    for pid in survivors:
        if pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
                log(f"Sent SIGKILL to stale bridge pid {pid}.")
            except ProcessLookupError:
                pass
            except PermissionError as exc:
                log(f"Cannot kill pid {pid}: {exc}")

    survivors = wait_until_stopped(survivors, 1)
    if survivors:
        lines = ", ".join(f"{pid}: {command_for_pid(pid)}" for pid in survivors)
        raise SystemExit(f"Cannot stop stale bridge process(es): {lines}")

    restore_hosts()
    try:
        PIDFILE.unlink()
    except FileNotFoundError:
        pass


def recv_exact(sock, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise OSError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def check_socks_available():
    try:
        with socket.create_connection((SOCKS_HOST, SOCKS_PORT), timeout=3) as sock:
            sock.sendall(b"\x05\x01\x00")
            return recv_exact(sock, 2) == b"\x05\x00"
    except Exception:
        return False


def parse_sni(data):
    try:
        if len(data) < 5 or data[0] != 0x16:
            return None
        record_len = struct.unpack("!H", data[3:5])[0]
        body = data[5 : 5 + record_len]
        if len(body) < 42 or body[0] != 0x01:
            return None
        pos = 4 + 2 + 32
        session_len = body[pos]
        pos += 1 + session_len
        cipher_len = struct.unpack("!H", body[pos : pos + 2])[0]
        pos += 2 + cipher_len
        comp_len = body[pos]
        pos += 1 + comp_len
        ext_total = struct.unpack("!H", body[pos : pos + 2])[0]
        pos += 2
        end = pos + ext_total
        while pos + 4 <= end:
            ext_type = struct.unpack("!H", body[pos : pos + 2])[0]
            ext_len = struct.unpack("!H", body[pos + 2 : pos + 4])[0]
            ext = body[pos + 4 : pos + 4 + ext_len]
            if ext_type == 0:
                list_len = struct.unpack("!H", ext[0:2])[0]
                ep = 2
                while ep + 3 <= 2 + list_len:
                    name_type = ext[ep]
                    name_len = struct.unpack("!H", ext[ep + 1 : ep + 3])[0]
                    ep += 3
                    if name_type == 0:
                        return ext[ep : ep + name_len].decode("idna")
                    ep += name_len
            pos += 4 + ext_len
    except Exception:
        return None
    return None


def socks_connect(target_host, target_port):
    sock = socket.create_connection((SOCKS_HOST, SOCKS_PORT), timeout=10)
    sock.sendall(b"\x05\x01\x00")
    resp = recv_exact(sock, 2)
    if resp != b"\x05\x00":
        raise OSError(f"SOCKS handshake failed: {resp!r}")
    host_bytes = target_host.encode("idna")
    req = b"\x05\x01\x00\x03" + bytes([len(host_bytes)]) + host_bytes + struct.pack("!H", target_port)
    sock.sendall(req)
    resp = recv_exact(sock, 4)
    if resp[1] != 0:
        raise OSError(f"SOCKS connect failed: {resp!r}")
    atyp = resp[3]
    if atyp == 1:
        recv_exact(sock, 4)
    elif atyp == 3:
        ln = recv_exact(sock, 1)[0]
        recv_exact(sock, ln)
    elif atyp == 4:
        recv_exact(sock, 16)
    recv_exact(sock, 2)
    return sock


def pipe(a, b):
    sockets = [a, b]
    while not stop_event.is_set():
        readable, _, _ = select.select(sockets, [], [], 1)
        if not readable:
            continue
        for src in readable:
            dst = b if src is a else a
            data = src.recv(65536)
            if not data:
                return
            dst.sendall(data)


def handle(client, addr):
    upstream = None
    try:
        client.settimeout(5)
        first = client.recv(8192)
        if not first:
            return
        sni = parse_sni(first) or DEFAULT_TARGET
        upstream = socks_connect(sni, 443)
        log(f"{addr} -> {sni}:443 via SOCKS {SOCKS_HOST}:{SOCKS_PORT}")
        upstream.sendall(first)
        client.settimeout(None)
        upstream.settimeout(None)
        pipe(client, upstream)
    except Exception as exc:
        log(f"Connection from {addr} failed: {exc}")
    finally:
        try:
            client.close()
        except Exception:
            pass
        if upstream:
            try:
                upstream.close()
            except Exception:
                pass


def reserve_listener(host):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    srv = socket.socket(family, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    srv.bind((host, LISTEN_PORT))
    srv.listen(128)
    return srv


def accept_loop(srv, label):
    log(f"Listening on {label}:{LISTEN_PORT}")
    while not stop_event.is_set():
        try:
            readable, _, _ = select.select([srv], [], [], 1)
            if readable:
                client, addr = srv.accept()
                threading.Thread(target=handle, args=(client, addr), daemon=True).start()
        except OSError:
            break


def close_listeners():
    for srv in listener_sockets:
        try:
            srv.close()
        except Exception:
            pass
    listener_sockets.clear()


def hosts_status():
    text = HOSTS.read_text() if HOSTS.exists() else ""
    begin = text.find(BEGIN)
    end = text.find(END, begin + len(BEGIN)) if begin >= 0 else -1
    if begin < 0 or end < 0:
        return False, DOMAINS[:]
    block = text[begin:end]
    missing = [domain for domain in DOMAINS if domain not in block]
    return True, missing


def port_status():
    result = subprocess.run(
        ["/usr/bin/nc", "-z", "127.0.0.1", str(LISTEN_PORT)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode == 0:
        return True, "127.0.0.1 accepts TCP connections"
    return False, result.stdout.strip()


def port_owner_summary():
    owners = bridge_process_lines()
    if owners:
        return owners
    try:
        output = subprocess.check_output(
            ["/usr/sbin/lsof", "-nP", "-iTCP:443", "-sTCP:LISTEN"],
            stderr=subprocess.STDOUT,
            text=True,
        ).strip()
        return output.splitlines()
    except Exception:
        return []


def print_status():
    hosts_present, missing = hosts_status()
    port_listening, lsof_output = port_status()
    pids = bridge_pids()
    payload = {
        "version": BRIDGE_VERSION,
        "domains": DOMAINS,
        "hostsPresent": hosts_present,
        "missingDomains": missing,
        "portListening": port_listening,
        "socksAvailable": check_socks_available(),
        "pids": pids,
        "processes": bridge_process_lines(),
        "pidfilePid": pidfile_pid(),
        "launchdState": launchd_state(),
        "launchdPlist": str(LAUNCHD_PLIST),
        "portOwners": port_owner_summary() if port_listening else [],
        "lsof": lsof_output,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if payload["hostsPresent"] and not payload["missingDomains"] and payload["portListening"] and payload["socksAvailable"] and pids else 2


def request_stop(signum, frame):
    stop_event.set()
    close_listeners()


def start_bridge(stop_stale=True):
    if stop_stale:
        stop_existing()
    if not check_socks_available():
        raise SystemExit(f"Veee SOCKS is not reachable at {SOCKS_HOST}:{SOCKS_PORT}. Start Veee first.")

    try:
        for host in ("127.0.0.1", "::1"):
            listener_sockets.append(reserve_listener(host))
    except Exception as exc:
        close_listeners()
        restore_hosts()
        raise SystemExit(f"Cannot bind local {LISTEN_PORT}: {exc}. Owners: {port_owner_summary()}")

    install_hosts()
    PIDFILE.write_text(str(os.getpid()))
    try:
        for srv, label in zip(listener_sockets, ("127.0.0.1", "::1")):
            threading.Thread(target=accept_loop, args=(srv, label), daemon=True).start()
        log(f"Bridge v{BRIDGE_VERSION} is running in foreground. Press Ctrl+C to stop and restore hosts.")
        while not stop_event.is_set():
            time.sleep(0.5)
    finally:
        stop_event.set()
        close_listeners()
        restore_hosts()
        try:
            PIDFILE.unlink()
        except FileNotFoundError:
            pass


def start_daemon():
    unload_launchd_service()
    stop_existing(unload_launchd=False)
    if not check_socks_available():
        raise SystemExit(f"Veee SOCKS is not reachable at {SOCKS_HOST}:{SOCKS_PORT}. Start Veee first.")

    script_path = Path(__file__).resolve()
    install_launchd_service(script_path)

    deadline = time.time() + 8
    last_status = ""
    while time.time() < deadline:
        hosts_present, missing = hosts_status()
        port_listening, last_status = port_status()
        current_pidfile = pidfile_pid()
        if hosts_present and not missing and port_listening and current_pidfile and pid_alive(current_pidfile):
            log(f"Bridge daemon started under launchd. pid={current_pidfile}, log={LOGFILE}")
            return
        time.sleep(0.2)

    raise SystemExit(
        f"Timed out waiting for bridge daemon to start. Last status: {last_status}. "
        f"pidfile={pidfile_pid()}, launchd={launchd_state()}, owners={port_owner_summary()}"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repair", action="store_true", help="stop stale bridge state, then start cleanly")
    parser.add_argument("--daemon", action="store_true", help="start bridge in the background and exit")
    parser.add_argument("--foreground", action="store_true", help="run foreground bridge without stopping existing state")
    parser.add_argument("--status", action="store_true", help="print bridge status as JSON")
    parser.add_argument("--stop", action="store_true", help="stop bridge processes and restore /etc/hosts")
    parser.add_argument("--restore", action="store_true", help="restore /etc/hosts and exit")
    args = parser.parse_args()

    if args.status:
        sys.exit(print_status())

    require_root()
    if args.stop:
        stop_existing()
        return
    if args.restore:
        restore_hosts()
        return

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    if args.daemon:
        start_daemon()
    else:
        start_bridge(stop_stale=not args.foreground)


if __name__ == "__main__":
    main()
"""#
}
