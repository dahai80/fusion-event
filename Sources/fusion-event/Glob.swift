import Foundation

public enum Glob {
    public static let maxSteps = 200_000

    public static func match(pattern: String?, path: String) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        let matcher = GlobMatcher(pattern: Array(pattern), path: Array(path))
        return matcher.run()
    }
}

private final class GlobMatcher {
    private let pattern: [Character]
    private let path: [Character]
    private let pLen: Int
    private let sLen: Int
    private var memo: [Int: Bool] = [:]
    private var steps = 0

    init(pattern: [Character], path: [Character]) {
        self.pattern = pattern
        self.path = path
        self.pLen = pattern.count
        self.sLen = path.count
    }

    func run() -> Bool {
        let r = dfs(p: 0, s: 0)
        if steps >= Glob.maxSteps {
            FusionLog.rule.error("glob step cap exceeded, pattern too complex, reject match")
            return false
        }
        return r
    }

    private func key(_ p: Int, _ s: Int) -> Int { p * (sLen + 1) + s }

    private func dfs(p: Int, s: Int) -> Bool {
        if steps >= Glob.maxSteps { return false }
        steps += 1
        let k = key(p, s)
        if let cached = memo[k] { return cached }
        var result = false
        if p == pLen {
            result = s == sLen
        } else if pattern[p] == "*" && p + 1 < pLen && pattern[p + 1] == "*" {
            var nextP = p + 2
            if nextP < pLen && pattern[nextP] == "/" { nextP += 1 }
            if nextP == pLen {
                result = true
            } else {
                for i in s...sLen {
                    if dfs(p: nextP, s: i) { result = true; break }
                }
            }
        } else if pattern[p] == "*" {
            if s == sLen {
                result = dfs(p: p + 1, s: s)
            } else if path[s] == "/" {
                result = dfs(p: p + 1, s: s)
            } else {
                if dfs(p: p + 1, s: s) { result = true } else { result = dfs(p: p, s: s + 1) }
            }
        } else if pattern[p] == "?" {
            if s < sLen && path[s] != "/" {
                result = dfs(p: p + 1, s: s + 1)
            } else {
                result = false
            }
        } else {
            if s < sLen && pattern[p] == path[s] {
                result = dfs(p: p + 1, s: s + 1)
            } else {
                result = false
            }
        }
        memo[k] = result
        return result
    }
}
