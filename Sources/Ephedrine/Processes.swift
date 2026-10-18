import Darwin
import EphedrineCore

/// Every process on the Mac (pid, parent, start time) from one
/// `sysctl(KERN_PROC_ALL)` read. Empty if the read fails; callers treat empty
/// as "unknown", never as "nothing running".
func processSnapshot() -> [ProcEntry] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    let stride = MemoryLayout<kinfo_proc>.stride
    for _ in 0..<3 {   // the table can grow between the size query and the read
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4   // 25% headroom
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        var len = buf.count * stride
        let r = buf.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &len, nil, 0) }
        if r != 0 { if errno == ENOMEM { continue } else { return [] } }
        return buf.prefix(len / stride).map { k in
            let t = k.kp_proc.p_un.__p_starttime
            return ProcEntry(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid,
                             start: Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec))
        }
    }
    return []
}
