import Foundation

public enum Glob {
    public static func match(pattern: String?, path: String) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        return matchSegment(pattern: Array(pattern), path: Array(path), pIdx: 0, sIdx: 0)
    }

    private static func matchSegment(pattern: [Character], path: [Character], pIdx: Int, sIdx: Int) -> Bool {
        var p = pIdx
        var s = sIdx
        while p < pattern.count {
            let pc = pattern[p]
            if pc == "*" {
                if p + 1 < pattern.count && pattern[p + 1] == "*" {
                    var nextP = p + 2
                    if nextP < pattern.count && pattern[nextP] == "/" { nextP += 1 }
                    for var i in s...path.count {
                        if matchSegment(pattern: pattern, path: path, pIdx: nextP, sIdx: i) { return true }
                        if i < path.count && path[i] == "/" { i += 0 }
                    }
                    return false
                } else {
                    while s < path.count && path[s] != "/" {
                        if matchSegment(pattern: pattern, path: path, pIdx: p + 1, sIdx: s) { return true }
                        s += 1
                    }
                    return matchSegment(pattern: pattern, path: path, pIdx: p + 1, sIdx: s)
                }
            } else {
                if s >= path.count { return false }
                if pc == "?" {
                    if path[s] == "/" { return false }
                    p += 1; s += 1
                    continue
                }
                if pc != path[s] { return false }
                p += 1; s += 1
            }
        }
        return s == path.count
    }
}
