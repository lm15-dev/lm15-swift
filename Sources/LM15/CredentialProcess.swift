import Foundation
import CProcess
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private final class ProcessControl: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws { guard let p = lm15_process_create() else { throw AuthError("credential process allocation failed") }; pointer = p }
    deinit { lm15_process_destroy(pointer) }
    func cancel() { lm15_process_cancel(pointer) }
}
enum CredentialProcess {
    static func run(executable: String, arguments: [String], environment: [String:String], timeout: TimeInterval) async throws -> String {
        guard timeout.isFinite && timeout > 0 && timeout <= 3600, !([executable]+arguments+environment.map { $0.key+"="+$0.value }).contains(where: { $0.utf8.contains(0) }) else { throw ValueError("invalid credential process arguments or timeout") }
        let control = try ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached {
                let args = ([executable]+arguments).map { strdup($0) } + [nil]
                let env = environment.keys.sorted().map { strdup($0+"="+environment[$0]!) } + [nil]
                defer { args.forEach { free($0) }; env.forEach { free($0) } }
                var data = [UInt8](repeating:0,count:4*1024*1024), length = 0
                let code = args.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { envp in data.withUnsafeMutableBufferPointer { output in lm15_process_run(control.pointer,executable,argv.baseAddress!,envp.baseAddress!,Int32(timeout*1000),output.baseAddress!,output.count,&length) } } }
                switch code {
                case 0: return String(decoding:data.prefix(length),as:UTF8.self)
                case -3: throw NotConfiguredError("credential helper processes are unavailable on this platform")
                case -4: throw AuthError("credential command timed out")
                case -5: throw CancellationError()
                case -6: throw AuthError("credential command output exceeded 4 MiB")
                default: throw AuthError("credential command failed")
                }
            }.value
        },onCancel:{ control.cancel() })
    }
}
