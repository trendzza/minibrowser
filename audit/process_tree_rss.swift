// process_tree_rss.swift
// Measures the full process-tree RSS of an app by name (mini build of what
// MemGuard does) plus optional per-process breakdown and CPU. No third-party
// deps; uses libproc like the browser's MemGuard.
//
// usage:
//   swift process_tree_rss.swift "/Applications/Google Chrome.app"        # total RSS
//   swift process_tree_rss.swift "/Applications/Google Chrome.app" --breakdown
//   swift process_tree_rss.swift "/Applications/Google Chrome.app" --top N

import Foundation
import Darwin

func procPath(_ pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: 4096)
    let len = proc_pidpath(pid, &path, UInt32(path.count))
    guard len > 0 else { return nil }
    return String(cString: path)
}

func processName(_ pid: pid_t) -> String {
    URL(fileURLWithPath: procPath(pid) ?? "pid \(pid)").lastPathComponent
}

func rssBytes(_ pid: pid_t) -> UInt64 {
    var info = proc_taskinfo()
    let size = mach_msg_type_number_t(MemoryLayout<proc_taskinfo>.size / MemoryLayout<natural_t>.size)
    let ret = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
        }
    }
    return ret > 0 ? info.pti_resident_size : 0
}

func childPIDs(_ parent: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 1024)
    let written = proc_listchildpids(parent, &buffer,
                                     Int32(MemoryLayout<pid_t>.size * buffer.count))
    let count = Int(written) / MemoryLayout<pid_t>.size
    guard count > 0 else { return [] }
    return Array(buffer.prefix(count))
}

func allPIDs() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let written = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
    let count = Int(written) / MemoryLayout<pid_t>.size
    guard count > 0 else { return [] }
    return Array(pids.prefix(count))
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: process_tree_rss.swift <appPath> [--breakdown] [--top N]\n".data(using: .utf8)!)
    exit(1)
}
let appPath = args[1]
let wantBreakdown = args.contains("--breakdown")
var topN = 0
if let i = args.firstIndex(of: "--top") { topN = Int(args[i + 1]) ?? 0 }

// Find every PID whose executable path starts with the app path, then walk the
// whole tree (children + their children) so we capture descendants' descendants,
// which Chrome/WebKit spawn a lot of. Also sweep all pids whose path contains
// the app's bundle name (covers helper/XPC processes by executable name).
let bundleName = URL(fileURLWithPath: appPath).lastPathComponent.replacingOccurrences(of: ".app", with: "")
let all = allPIDs()

var roots = Set<pid_t>()
for pid in all {
    guard let p = procPath(pid) else { continue }
    if p.hasPrefix(appPath) {
        roots.insert(pid)
    }
}
// Sweep all processes to catch XPC wedges whose path shares the bundle name
// (e.g. "Chrome Helper", "MiniBrowser Helper") even if not under the .app dir.
for pid in all {
    guard let p = procPath(pid) else { continue }
    let name = URL(fileURLWithPath: p).lastPathComponent
    if name.contains(bundleName) {
        roots.insert(pid)
    }
}

var seen = Set<pid_t>()
var rows: [(pid: pid_t, name: String, rss: UInt64)] = []
var stack = Array(roots)
while let pid = stack.popLast() {
    guard !seen.contains(pid) else { continue }
    seen.insert(pid)
    let r = rssBytes(pid)
    if r > 0 { rows.append((pid, processName(pid), r)) }
    stack.append(contentsOf: childPIDs(pid))
}

let total = rows.reduce(UInt64(0)) { $0 + $1.rss }
let totalMB = Double(total) / (1024 * 1024)
let procCount = seen.count

if wantBreakdown || topN > 0 {
    let sorted = rows.sorted { $0.rss > $1.rss }
    let line = sorted.prefix(topN > 0 ? topN : sorted.count)
    print("== \(bundleName): \(procCount) procs, total \(String(format: "%.1f MB", totalMB)) ==")
    for r in line {
        print(String(format: "  %8.1f MB  %@ (%d)", Double(r.rss) / (1024 * 1024), r.name, r.pid))
    }
} else {
    print(String(format: "%.1f", totalMB))
}
