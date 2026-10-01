import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs a child process and collects its combined output.
///
/// `Foundation.Process` does not exist on iOS, so this is `posix_spawn` with a
/// pipe. It is synchronous on purpose: the callers are a command-line tool and a
/// background queue in the app, and a synchronous call cannot leak a file
/// descriptor when the caller loses interest.
public enum Subprocess {

    public struct Result: Sendable {
        public var executable: String
        public var arguments: [String]
        public var status: Int32
        public var output: String

        public var succeeded: Bool { status == 0 }

        public var commandLine: String {
            ([executable] + arguments)
                .map { $0.contains(" ") ? "'\($0)'" : $0 }
                .joined(separator: " ")
        }
    }

    public enum Failure: Error, LocalizedError {
        case pipe(errno: Int32)
        case spawn(executable: String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .pipe(let code):
                return "Could not create a pipe (errno \(code))."
            case .spawn(let executable, let code):
                return "Could not run \(executable) (spawn error \(code)). It may be missing, or not executable by this app."
            }
        }
    }

    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> Result {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.pipe(errno: errno) }

        // Darwin imports posix_spawn_file_actions_t as a nullable opaque pointer
        // (it must start as nil); glibc imports it as a value type. One of the
        // two needs a different declaration, and this is the only place that
        // knows which.
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        _ = posix_spawn_file_actions_init(&actions)
        _ = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&actions, descriptors[0])
        _ = posix_spawn_file_actions_addclose(&actions, descriptors[1])

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)

        var child: pid_t = 0
        let spawned: Int32
        if let environment {
            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
            envp.append(nil)
            spawned = posix_spawn(&child, executable, &actions, nil, &argv, &envp)
            for pointer in envp where pointer != nil { free(pointer) }
        } else {
            // A nil envp means "inherit", which is what a package manager wants:
            // apt-get needs PATH, HOME and the proxy variables it was given.
            spawned = posix_spawn(&child, executable, &actions, nil, &argv, nil)
        }
        posix_spawn_file_actions_destroy(&actions)
        for pointer in argv where pointer != nil { free(pointer) }

        guard spawned == 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw Failure.spawn(executable: executable, code: spawned)
        }

        // The parent has to drop its copy of the write end or the read below
        // never sees end of file.
        close(descriptors[1])

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptors[0], &buffer, buffer.count)
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        close(descriptors[0])

        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}

        // The wait(2) status word is not an exit code: the low seven bits hold
        // the signal that killed the child, the next byte the exit status. Swift
        // does not import the function-like macros that read it (WIFEXITED and
        // friends are "function like macros not supported"), so the layout is
        // spelled out.
        let signal = status & 0x7F
        let code: Int32
        if signal == 0 {
            code = (status >> 8) & 0xFF
        } else if signal != 0x7F {
            code = 128 + signal
        } else {
            code = status
        }

        return Result(
            executable: executable,
            arguments: arguments,
            status: code,
            output: String(decoding: collected, as: UTF8.self)
        )
    }

    @discardableResult
    public static func run(_ command: [String], environment: [String: String]? = nil) throws -> Result {
        guard let executable = command.first else {
            return Result(executable: "", arguments: [], status: 0, output: "")
        }
        return try run(executable: executable, arguments: Array(command.dropFirst()), environment: environment)
    }
}
