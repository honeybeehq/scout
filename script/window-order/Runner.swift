import Foundation
let contents = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
let verify = contents.deletingLastPathComponent().deletingLastPathComponent()
let lines = ((try? String(contentsOf: verify.appendingPathComponent("runner-args"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
let scout = lines[0]
let argv = lines.map { strdup($0) } + [nil]
execv(scout, argv)
perror("execv")
