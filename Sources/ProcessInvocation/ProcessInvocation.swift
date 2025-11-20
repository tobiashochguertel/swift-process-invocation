import Foundation

#if canImport(eXtenderZ)
import CNSTaskHelptender
import eXtenderZ
#endif
import SignalHandling
import StreamReader
import SystemPackage

#if !canImport(Darwin)
import CGNUSourceExports
#endif
import CMacroExports



/**
 A type representing a “process invocation,” that is all of the different parameters needed to launch a new sub-process.
 This type is also an `AsyncSequence`.
 
 The element of the async sequence is ``RawLineWithSource``, which represent a raw line of process output, with the source fd from which the line comes from.
 The sequence can throw
  before the first output line is issued because the process failed to launch,
  while receiving lines because there was an I/O error,
  or after all the lines have been received because the process had an unexpected termination (the expected terminations are customizable).
 
 When launched, the process will be launched in its own PGID.
 Which means, if your process is launched in a Terminal,
  then you spawn a process using this object,
  then the user types `Ctrl-C`,
 your process will be killed,
  but the process you launched won’t be.
 
 However, you have an option to forward some signals to the processes you spawn using this object.
 Some signals are forwarded by default.
 
 IMHO the signal forwarding method, though a bit more complex (in this case, a lot of the complexity is hidden by this object),
  is better than using the same PGID than the parent for the child.
 In a shell, if a long running process is launched from a bash script, and said bash script is killed using a signal
  (but from another process sending a signal, not from the tty), the child won’t be killed!
 Using signal forwarding, it will.
 
 Some interesting links:
 - [The TTY demystified](http://www.linusakesson.net/programming/tty/)
 - [SIGTTIN / SIGTTOU Deep Dive](http://curiousthing.org/sigttin-sigttou-deep-dive-linux)
 - [Swift Process class source code](https://github.com/apple/swift-corelibs-foundation/blob/swift-5.3.3-RELEASE/Sources/Foundation/Process.swift)
 
 - Important: For technical reasons (and design choice), if file descriptors to send is not empty, the process will be launched _via_ the `swift-process-invocation-bridge` executable.
 
 - Note: We use `Process` to spawn the process.
 This is why the process is launched in its own PGID
  and why we have to use `swift-process-invocation-bridge` to launch it to be able to pass other file descriptors than stdin/stdout/stderr to it.
 
 One day we might rewrite this function using `posix_spawn` directly…
 
 - Note: On Linux, the PGID stuff is not true up to Swift 5.3.3 (currently in production!)
 It is true on the `main` branch though (2021-04-01).
 
 - Important: All of the `additionalOutputFileDescriptors` are closed when the end of their respective stream are reached
  (i.e. the function takes “ownership” of the file descriptors).
 Maybe later we’ll add an option not to close at end of the stream.
 Additionally on Linux the fds will be set non-blocking
  (clients should not care as they have given up ownership of the fd, but it’s still good to know IMHO).
 
 - Important: AFAICT the absolute ref for `PATH` resolution is [from exec function in FreeBSD source](<https://opensource.apple.com/source/Libc/Libc-1439.100.3/gen/FreeBSD/exec.c.auto.html>) (end of file).
 Sadly `Process` does not report the actual errors and seem to always report “File not found” errors when the executable cannot be run.
 So we do not fully emulate exec’s behavior. 
 
 One final note: I recently discovered [this](<https://forums.developer.apple.com/forums/thread/690310>) by eskimo which does some of what we do in this struct. */
public struct ProcessInvocation : AsyncSequence {
	
	public typealias ProcessOutputHandler = (_ rawLineWithSource: RawLineWithSource, _ signalEndOfInterestForStream: () -> Void, _ process: Process) -> Void
	
	public typealias AsyncIterator = Iterator
	public typealias Element = RawLineWithSource
	
	public struct SignalHandling {
		
		public var signalForChild: Signal?
//		public var signalForParent: Signal? /* Changing the signal is not possible w/ swift-signal-handling, but it’s not a big deal. It could be done but has not. */
		public var allowOnParent: Bool
		public var sendToProcessGroupOfChild: Bool
		public var waitForChildDeathBeforeSendingToParent: Bool
		
		public static func `default`(for signal: Signal) -> Self {
			return .init(signalForChild: signal, waitForChildDeathBeforeSendingToParent: Signal.killingSignals.contains(signal))
		}
		
		public static func mapForChild(for signal: Signal, with map: [Signal: Signal]) -> Self {
			return .default(for: map[signal] ?? signal)
		}
		
		public init(signalForChild: Signal?, allowOnParent: Bool = true, sendToProcessGroupOfChild: Bool = true, waitForChildDeathBeforeSendingToParent: Bool = true) {
			self.signalForChild = signalForChild
			self.allowOnParent = allowOnParent
			self.sendToProcessGroupOfChild = sendToProcessGroupOfChild
			self.waitForChildDeathBeforeSendingToParent = waitForChildDeathBeforeSendingToParent
		}
		
	}
	
	public var executable: FilePath
	public var args: [String] = []
	
	/**
	 Try and search the executable in the `PATH` environment variable when the executable path is a simple word (shell-like search).
	 
	 If `false` (default) the standard `Process` behavior will apply: resolve the executable path just like any other path and execute that.
	 If not using `PATH` and there are fds to send, the `SWIFTPROCESSINVOCATION_BRIDGE_PATH` env var becomes mandatory.
	 We have to know the location of the `swift-process-invocation-bridge` executable.
	 If using `PATH` with fds to send, the `swift-process-invocation-bridge` executable is searched normally, except the `SWIFTPROCESSINVOCATION_BRIDGE_PATH` path is tried first, if defined.
	 The environment is never modified (neither for the executed process nor the current one), regardless of this variable or whether there are additional fds to send.
	 The `PATH` is modified for the `swift-process-invocation-bridge` launcher when sending fds (and only for it) so that all paths are absolute though.
	 The subprocess will still see the original `PATH`.
	 
	 - Note: Setting ``usePATH`` to `false` or ``customPATH`` to an empty array is technically equivalent.
	 (But setting ``usePATH`` to `false` is marginally faster). */
	public var usePATH: Bool = true
	/**
	 Override the PATH environment variable and use this.
	 
	 Empty strings are the same as “`.`”.
	 This parameter allows having a “PATH” containing colons, which the standard `PATH` variable does not allow.
	 _However_ this does not work when there are fds to send, in which case the paths containing colons are **removed** (for security reasons).
	 Maybe one day we’ll enable it in this case too, but for now it’s not enabled.
	 
	 Another difference when there are fds to send regarding the PATH is all the paths are made absolute.
	 This avoids any problem when the ``workingDirectory`` parameter is set to a non-null value.
	 
	 Finally the parameter is a double-optional.
	 It can be set
	  to `.none`, which means the default `PATH` env variable will be used,
	  to `.some(.none)`, in which case the default `PATH` is used (`_PATH_DEFPATH`, see `exec(3)`) or
	  to a non-`nil` value, in which case this value is used. */
	public var customPATH: [FilePath]?? = nil
	
	public var workingDirectory: URL? = nil
	public var environment: [String: String]? = nil
	
	public var stdinRedirect: InputRedirectMode = .none()
	public var stdoutRedirect: OutputRedirectMode = .capture
	public var stderrRedirect: OutputRedirectMode = .capture
	
	public var signalsToProcess: Set<Signal> = Signal.toForwardToSubprocesses
	public var signalHandling: (Signal) -> SignalHandling
	
	/**
	 The file descriptors (other than `stdin`, `stdout` and `stderr`, which are handled differently) to clone in the child process.
	 They are closed once the process has been launched.
	 
	 The **value** is the file descriptor to clone (from the parent process to the child),
	 the key is the descriptor you’ll get in the child process.
	 
	 - Important: The function takes ownership of these file descriptors, i.e. it closes them when the process has been launched.
	 You should dup your fds if you need to keep a ref to them. */
	public var fileDescriptorsToSend: [FileDescriptor /* Value in **child** */: FileDescriptor /* Value in **parent** */] = [:]
	/**
	 Additional output file descriptors to stream from the process.
	 
	 Usually used with ``fileDescriptorsToSend``
	 (you open a socket, give the write fd in fds to clone, and the read fd to additional output fds).
	 
	 - Important: The function takes ownership of these file descriptors, i.e. it closes them when the end of their respective streams is reached.
	 You should dup your fds if you need to keep a ref to them. */
	public var additionalOutputFileDescriptors: Set<FileDescriptor> = []
	
	/**
	 The line separator to expect in the process output.
	 Usually will be a simple newline character, but can also be the zero char (e.g. `find -print0`), or windows newlines, or something else.
	 
	 This property should probably not be part of a ``ProcessInvocation`` per se as
	 technically the process could be invoked whether this is known or not.
	 However,
	  because ``ProcessInvocation`` is an `AsyncSequence`,
	  and we cannot specify options when iterating on a sequence,
	 we have to know in advance the line separator to expect!
	 
	 One could probably argue
	  the `ProcessInvocation` sequence element should be of type `UInt8` and
	  we’d receive all the bytes one after the other, and
	  we’d wrap the ProcessInvocation in an `AsyncLineSequence` to get the lines of text.
	 
	 We have the following counterpoints:
	 1. The `AsyncLineSequence` cannot be customized (AFAICT), and we _have to_ trust it do to the right thing
	 (which will necessarily not be the right thing when processing the output of `find -print0` for instance).
	 This could be worked-around by creating a specific wrapping sequence, just like `AsyncLineSequence`, but customizable,
	 or by using another sequence wrapper for the `print0` option;
	 2. Sending the bytes one by one is probably (to be tested) slower than sending chunks of data directly;
	 3. We have a bit of history with this API, and we have a primitive to split the lines in a stream already.
	 
	 So, for simplicity, we leave it that way, at least for now. */
	public var lineSeparators: LineSeparators = .default
	/**
	 A global handler called after each new lines of text to check if the client is still interested in the stream.
	 If it is not, the stream will be closed.
	 
	 The handler is set at process invocation time:
	 when the process is invoked, if this property is modified, the original handler will still be called. */
	public var shouldContinueStreamHandler: ((_ line: RawLineWithSource, _ process: Process) -> Bool)?
	
	/**
	 The terminations to expect from the process.
	 
	 Much like ``lineSeparators``
	  this property should probably not be a part of ``ProcessInvocation``,
	  but like ``lineSeparators``, because ``ProcessInvocation`` is an AsyncSequence
	 we have to know in advance the expected terminations of the process
	  in order to be able to correctly throw when process is over if termination is unexpected. */
	public var expectedTerminations: [(Int32, Process.TerminationReason)]?
	
	public init(
		_ executable: FilePath, _ args: String..., usePATH: Bool = true, customPATH: [FilePath]?? = nil,
		workingDirectory: URL? = nil, environment: [String: String]? = nil,
		stdinRedirect: InputRedirectMode = .none(), stdoutRedirect: OutputRedirectMode = .capture, stderrRedirect: OutputRedirectMode = .capture,
		signalsToProcess: Set<Signal> = Signal.toForwardToSubprocesses,
		signalHandling: @escaping (Signal) -> SignalHandling = { .default(for: $0) },
		fileDescriptorsToSend: [FileDescriptor /* Value in **child** */: FileDescriptor /* Value in **parent** */] = [:],
		additionalOutputFileDescriptors: Set<FileDescriptor> = [],
		lineSeparators: LineSeparators = .default,
		shouldContinueStreamHandler: ((_ line: RawLineWithSource, _ process: Process) -> Bool)? = nil,
		expectedTerminations: [(Int32, Process.TerminationReason)]?? = nil
	) {
		self.init(
			executable, args: args, usePATH: usePATH, customPATH: customPATH,
			workingDirectory: workingDirectory, environment: environment,
			stdinRedirect: stdinRedirect, stdoutRedirect: stdoutRedirect, stderrRedirect: stderrRedirect,
			signalsToProcess: signalsToProcess,
			signalHandling: signalHandling,
			fileDescriptorsToSend: fileDescriptorsToSend,
			additionalOutputFileDescriptors: additionalOutputFileDescriptors,
			lineSeparators: lineSeparators,
			shouldContinueStreamHandler: shouldContinueStreamHandler,
			expectedTerminations: expectedTerminations
		)
	}
	
	/**
	 Init a process invocation.
	 
	 - Parameter expectedTerminations: A double-optional to define the expected terminations.
	 If left at default (set to `nil`), the expected termination will be
	  a standard exit with exit code 0 if there are no ``shouldContinueStreamHandler`` defined, and
	  a standard exit with exit code 0 + broken pipe exception exit otherwise.
	 If set to `.some(.none)`, the expected termination will be set to nil, in which case any termination pass the termination check.
	 If set to a non-optional value, the expected terminations will be set to this value. */
	public init(
		_ executable: FilePath, args: [String], usePATH: Bool = true, customPATH: [FilePath]?? = nil,
		workingDirectory: URL? = nil, environment: [String: String]? = nil,
		stdinRedirect: InputRedirectMode = .none(), stdoutRedirect: OutputRedirectMode = .capture, stderrRedirect: OutputRedirectMode = .capture,
		signalsToProcess: Set<Signal> = Signal.toForwardToSubprocesses,
		signalHandling: @escaping (Signal) -> SignalHandling = { .default(for: $0) },
		fileDescriptorsToSend: [FileDescriptor /* Value in **child** */: FileDescriptor /* Value in **parent** */] = [:],
		additionalOutputFileDescriptors: Set<FileDescriptor> = [],
		lineSeparators: LineSeparators = .default,
		shouldContinueStreamHandler: ((_ line: RawLineWithSource, _ process: Process) -> Bool)? = nil,
		expectedTerminations: [(Int32, Process.TerminationReason)]?? = nil
	) {
		self.executable = executable
		self.args = args
		self.usePATH = usePATH
		self.customPATH = customPATH
		
		self.workingDirectory = workingDirectory
		self.environment = environment
		
		self.stdinRedirect = stdinRedirect
		self.stdoutRedirect = stdoutRedirect
		self.stderrRedirect = stderrRedirect
		
		self.signalsToProcess = signalsToProcess
		self.signalHandling = signalHandling
		
		self.fileDescriptorsToSend = fileDescriptorsToSend
		self.additionalOutputFileDescriptors = additionalOutputFileDescriptors
		
		self.lineSeparators = lineSeparators
		
		self.shouldContinueStreamHandler = shouldContinueStreamHandler
		switch expectedTerminations {
			case .none:               self.expectedTerminations = (shouldContinueStreamHandler == nil ? [(0, .exit)] : [(0, .exit), (Signal.brokenPipe.rawValue, .uncaughtSignal)])
			case .some(.none):        self.expectedTerminations = nil
			case .some(.some(let v)): self.expectedTerminations = v
		}
	}
	
	public func makeAsyncIterator() -> Iterator {
		return Iterator(invocation: self)
	}
	
	/**
	 Invoke the process, then returns stdout lines.
	 
	 When using this method, the end of lines are lost.
	 Each line is stripped of the end of line separator.
	 Usually not a big deal; basically it means you won’t know if the last line had the end of line separator or not.
	 If you need this information, use ``invokeAndGetOutput(encoding:)``. */
	public func invokeAndGetStdout(encoding: String.Encoding = .utf8) async throws -> [String] {
		return try await invokeAndGetStdout(checkValidTerminations: true, encoding: encoding).0
	}
	
	public func invokeAndGetOutput(encoding: String.Encoding = .utf8) async throws -> [LineWithSource] {
		return try await invokeAndGetOutput(checkValidTerminations: true, encoding: encoding).0
	}
	
	public func invokeAndGetRawOutput() async throws -> [RawLineWithSource] {
		return try await invokeAndGetRawOutput(checkValidTerminations: true).0
	}
	
	public func invokeAndStreamOutput(outputHandler: @escaping ProcessInvocation.ProcessOutputHandler) async throws {
		_ = try await invokeAndStreamOutput(checkValidTerminations: true, outputHandler: outputHandler)
	}
	
	public func invokeAndGetStdout(checkValidTerminations: Bool, encoding: String.Encoding = .utf8) async throws -> ([String], Int32, Process.TerminationReason) {
		let (output, exitStatus, exitReason) = try await invokeAndGetOutput(checkValidTerminations: checkValidTerminations, encoding: encoding)
		return (output.compactMap{ $0.fd == .standardOutput ? $0.line : nil }, exitStatus, exitReason)
	}
	
	public func invokeAndGetOutput(checkValidTerminations: Bool, encoding: String.Encoding = .utf8) async throws -> ([LineWithSource], Int32, Process.TerminationReason) {
		let (rawOutput, exitStatus, exitReason) = try await invokeAndGetRawOutput(checkValidTerminations: checkValidTerminations)
		return try (rawOutput.map{ try $0.strLineWithSource(encoding: encoding) }, exitStatus, exitReason)
	}
	
	/**
	 Launch the invocation and returns the output of the process.
	 If there are any I/O issues while reading the output file descriptors from the Process,
	  the whole invocation is considered failed and an error is thrown. */
	public func invokeAndGetRawOutput(checkValidTerminations: Bool) async throws -> ([RawLineWithSource], Int32, Process.TerminationReason) {
		var lines = [RawLineWithSource]()
		let (exitStatus, exitReason) = try await invokeAndStreamOutput(checkValidTerminations: checkValidTerminations, outputHandler: { line, _, _ in
			lines.append(line)
		})
		return (lines, exitStatus, exitReason)
	}
	
	/**
	 Launch the invocation and streams the output in the given handler.
	 If there is at least one error reading from _any_ of the input stream at any given time,
	  the whole function will throw an ``ProcessInvocationError/outputReadError(_:)`` error,
	  and any new lines that might be received on other streams are not sent to the handler anymore.
	 The process is not stopped though, and it is waited on normally.
	 
	 - Parameter outputHandler: This handler is called after a new line is caught from any of the output file descriptors.
	 You get
	  the line and the separator as `Data`,
	  the source fd that generated this data (if `stdout` or `stderr` were set to `.capture`, you’ll get resp. the `stdout`/`stderr` fds even though the data is not technically coming from these)
	  and the source process.
	 You are also given a handler you can call to notify the end of interest in the stream (which closes the corresponding fd).
	 __Important__: Do **not** close the fd yourself.
	 Do not do any action on the fd actually.
	 Especially, do not read from it. */
	public func invokeAndStreamOutput(checkValidTerminations: Bool, outputHandler: @escaping ProcessInvocation.ProcessOutputHandler) async throws -> (Int32, Process.TerminationReason) {
		/* We want this variable to be immutable once the process is launched. */
		let expectedTerminations = expectedTerminations
		
		/* 1. First launch the process. */
		var outputError: Error?
		let (p, g) = try invoke{ result, signalEndOfInterestForStream, process in
			guard outputError == nil else {
				/* We do not signal end of interest in stream when we have an output error to avoid forcing a broken pipe error,
				 * _but_ we stop reading from any stream as soon as we get at least one error. */
				return
			}
			switch result {
				case .success(let line): outputHandler(line, signalEndOfInterestForStream, process)
				case .failure(let error): outputError = error
			}
		}
		/* 2. Then wait for it to quit and all the stream to be read fully. */
		await withCheckedContinuation{ continuation in
			g.notify(queue: ProcessInvocation.streamQueue, execute: {
				continuation.resume()
			})
		}
		/* 3. If there was an error reading the process output, we throw. */
		try outputError?.throw{ Err.outputReadError($0) }
		/* 4. Retrieve process termination status+reason and check them if needed. */
		let (exitStatus, exitReason) = (p.terminationStatus, p.terminationReason)
		if checkValidTerminations {
			try Self.checkTermination(expectedTerminations: expectedTerminations, terminationStatus: exitStatus, terminationReason: exitReason)
		}
		/* 5. We’re done, everything went well! */
		return (exitStatus, exitReason)
	}
	
	/**
	 Invoke the process but does not wait on it.
	 
	 You retrieve the process and a dispatch group you can wait on to be notified when the process and all of its outputs are done.
	 You can also set the termination handler of the process, but you should wait on the dispatch group to be sure all of the outputs have finished streaming. */
	public func invoke(outputHandler: @escaping (_ result: Result<RawLineWithSource, Error>, _ signalEndOfInterestForStream: () -> Void, _ process: Process) -> Void, terminationHandler: (@Sendable (_ process: Process) -> Void)? = nil) throws -> (Process, DispatchGroup) {
		assert(!fileDescriptorsToSend.keys.contains(.standardInput),   "Standard input must be modified using stdinRedirect")
		assert(!fileDescriptorsToSend.keys.contains(.standardOutput), "Standard output must be modified using stdoutRedirect")
		assert(!fileDescriptorsToSend.keys.contains(.standardError),   "Standard error must be modified using stderrRedirect")
		
		let g = DispatchGroup()
#if canImport(eXtenderZ)
		let p = Process()
#else
		let p = XcodeToolsProcess()
#endif
		
		let actualOutputHandler: (_ result: Result<RawLineWithSource, Error>, _ signalEndOfInterestForStream: () -> Void, _ process: Process) -> Void
		if let shouldContinueStreamHandler = shouldContinueStreamHandler {
			actualOutputHandler = { result, signalEndOfInterestForStream, process in
				outputHandler(result, signalEndOfInterestForStream, process)
				if case .success(let line) = result, !shouldContinueStreamHandler(line, process) {
					signalEndOfInterestForStream()
				}
			}
		} else {
			actualOutputHandler = outputHandler
		}
		
		p.terminationHandler = terminationHandler
		if let environment      = environment      {p.environment         = environment}
		if let workingDirectory = workingDirectory {p.currentDirectoryURL = workingDirectory}
		
		var fdsToCloseInCaseOfError = Set<FileDescriptor>()
		var fdToSwitchToBlockingInCaseOfError = Set<FileDescriptor>()
		var countOfDispatchGroupLeaveInCaseOfError = 0
		var signalCleaningOnError: (() -> Void)?
		func cleanupAndThrow(_ error: Error) throws -> Never {
			signalCleaningOnError?()
			for _ in 0..<countOfDispatchGroupLeaveInCaseOfError {g.leave()}
			
			/* Only the fds that are not ours, and thus not in additional output fds are allowed to be closed in case of error. */
			assert(additionalOutputFileDescriptors.intersection(fdsToCloseInCaseOfError).isEmpty)
			/* We only try and revert fds to blocking for fds we don’t own.
			 * Only those in additional output fds. */
			assert(additionalOutputFileDescriptors.isSuperset(of: fdToSwitchToBlockingInCaseOfError))
			/* The assert below is a consequence of the two above. */
			assert(fdsToCloseInCaseOfError.intersection(fdToSwitchToBlockingInCaseOfError).isEmpty)
			
			fdToSwitchToBlockingInCaseOfError.forEach{ fd in
				do    {try Self.removeRequireNonBlockingIO(on: fd)}
				catch {Conf.logger?.error("Cannot revert fd to blocking.", metadata: ["fd": "\(fd.rawValue)"])}
			}
			fdsToCloseInCaseOfError.forEach{ try? $0.close() }
			
			throw error
		}
		func cleanupIfThrows<R>(_ block: () throws -> R) rethrows -> R {
			do {return try block()}
			catch {
				try cleanupAndThrow(error)
			}
		}
		
		func getFgPgIDSetInfo(for fd: FileDescriptor) -> (destFd: FileDescriptor, originalValue: Int32)? {
			let originalPgrp = tcgetpgrp(fd.rawValue)
			guard originalPgrp != -1 else {
				if errno != ENOTTY {
					Conf.logger?.warning("Cannot determine the process group ID of the process that owns standard input; skipping foreground process group ID setting.", metadata: ["error": "\(Errno(rawValue: errno))"])
				} else {
					/* The ENOTTY error means the given fd does not have a TTY.
					 * Setting the fg process group of a fd w/o a TTY does not make sense, so we skip it with an info message instead of a warning. */
					Conf.logger?.info("The given file descriptor does not have a TTY; skipping foreground process group ID setting.")
				}
				return nil
			}
			return (fd, originalPgrp)
		}
		
		var fdsToCloseAfterRun = Set<FileDescriptor>()
		var fdRedirects = [FileDescriptor: FileDescriptor]()
		var outputFileDescriptors = additionalOutputFileDescriptors
		let fgPgIDSetInfo: (destFd: FileDescriptor, originalValue: Int32)?
		switch stdinRedirect {
			case .none(let setFgPgID): 
				p.standardInput = FileHandle.standardInput /* Already the case in theory as it is the default, but let’s be explicit. */
				fgPgIDSetInfo = (setFgPgID ? getFgPgIDSetInfo(for: FileDescriptor.standardInput) : nil)
				
			case .fromNull:
				p.standardInput = nil
				fgPgIDSetInfo = nil
				
			case .fromFd(let fd, let shouldClose, let setFgPgID):
				p.standardInput = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
				if shouldClose {
					assert(fileDescriptorsToSend.isEmpty, "Giving ownership to fd on stdin is not allowed when launching the process via the bridge. This is because stdin has to be sent via the bridge and we get only pain and race conditions to properly close the fd.")
					fdsToCloseAfterRun.insert(fd)
				}
				fgPgIDSetInfo = (setFgPgID ? getFgPgIDSetInfo(for: fd) : nil)
				
			case .sendFromReader(let reader):
				assert(fileDescriptorsToSend.isEmpty, "Sending data to stdin via a reader is not allowed when launching the process via the bridge. This is because stdin has to be sent via the bridge and we get only pain and race conditions to properly close the fd.")
				let fd = try Self.readFdOfPipeForStreaming(dataFromReader: reader, maxCacheSize: 32 * 1024 * 1024)
				fdsToCloseAfterRun.insert(fd)
				p.standardInput = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
				/* TODO: If we fail later, should the write end of the pipe be closed? */
				fgPgIDSetInfo = nil
		}
		switch stdoutRedirect {
			case .none: p.standardOutput = FileHandle.standardOutput /* Already the case in theory as it is the default, but let’s be explicit. */
			case .toNull: p.standardOutput = nil
			case .toFd(let fd, let shouldClose):
				p.standardOutput = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
				if shouldClose {fdsToCloseAfterRun.insert(fd)}
				
			case .capture:
				/* We use an unowned pipe because we want absolute control on when either side of the pipe is closed. */
				let (fdForReading, fdForWriting) = try Self.unownedPipe()
				
				let (inserted, _) = outputFileDescriptors.insert(fdForReading); assert(inserted)
				fdRedirects[fdForReading] = FileDescriptor.standardOutput
				
				fdsToCloseAfterRun.insert(fdForWriting)
				fdsToCloseInCaseOfError.insert(fdForReading)
				fdsToCloseInCaseOfError.insert(fdForWriting)
				
				Conf.logger?.trace("Got stdout pipe.", metadata: ["read_fd": "\(fdForReading.rawValue)", "write_fd": "\(fdForWriting.rawValue)"])
				p.standardOutput = FileHandle(fileDescriptor: fdForWriting.rawValue, closeOnDealloc: false)
		}
		switch stderrRedirect {
			case .none: p.standardError = FileHandle.standardError /* Already the case in theory as it is the default, but let’s be explicit. */
			case .toNull: p.standardError = nil
			case .toFd(let fd, let shouldClose):
				p.standardError = FileHandle(fileDescriptor: fd.rawValue, closeOnDealloc: false)
				if shouldClose {fdsToCloseAfterRun.insert(fd)}
				
			case .capture:
				let (fdForReading, fdForWriting) = try Self.unownedPipe()
				
				let (inserted, _) = outputFileDescriptors.insert(fdForReading); assert(inserted)
				fdRedirects[fdForReading] = FileDescriptor.standardError
				
				fdsToCloseAfterRun.insert(fdForWriting)
				fdsToCloseInCaseOfError.insert(fdForReading)
				fdsToCloseInCaseOfError.insert(fdForWriting)
				
				Conf.logger?.trace("Got stdout pipe.", metadata: ["read_fd": "\(fdForReading.rawValue)", "write_fd": "\(fdForWriting.rawValue)"])
				p.standardError = FileHandle(fileDescriptor: fdForWriting.rawValue, closeOnDealloc: false)
		}
		
#if canImport(Darwin)
		let platformSpecificInfo: Void = ()
#else
		var platformSpecificInfo = StreamReadPlatformSpecificInfo()
#endif
		
#if !canImport(Darwin)
		for fd in outputFileDescriptors {
			/* Let’s see if the fd is a master pt or not.
			 * This is needed to detect EOF properly and not throw an error when reading from a master pt (see handleProcessOutput for more info). */
			if spi_ptsname(fd.rawValue) == nil {
				let error = SystemPackage.Errno(rawValue: errno)
				if error.rawValue != ENOTTY {
					Conf.logger?.warning("Cannot determine whether fd is a master pt or not; assuming it’s not.", metadata: ["fd": "\(fd.rawValue)", "error": "\(error)"])
				}
			} else {
				Conf.logger?.trace("Found an output file descriptor which seems to be a master pt.", metadata: ["fd": "\(fd.rawValue)"])
				platformSpecificInfo.masterPTFileDescriptors.insert(fd)
			}
			try cleanupIfThrows{
				let isFromClient = additionalOutputFileDescriptors.contains(fd)
				/* I did not find any other way than using non-blocking IO on Linux.
				 * <https://stackoverflow.com/questions/39173429/one-shot-level-triggered-epoll-does-epolloneshot-imply-epollet/46142976#comment121697690_46142976> */
				try Self.setRequireNonBlockingIO(on: fd, logChange: isFromClient)
				if isFromClient {
					/* The fd is not ours.
					 * We must try and revert it to its original state if the function throws an error. */
					assert(!fdsToCloseInCaseOfError.contains(fd))
					fdToSwitchToBlockingInCaseOfError.insert(fd)
				}
			}
		}
#endif
		
		let fdToSendFds: FileDescriptor?
		/* We will modify it later to add stdin if needed. */
		var fileDescriptorsToSend = fileDescriptorsToSend
		
		/* Let’s compute the PATH. */
		/** The resolved PATH */
		let PATH: [FilePath]
		/** `true` if the default `_PATH_DEFPATH` path is used.
		 The variable is used when using the `swift-process-invocation-bridge` launcher. */
		let isDefaultPATH: Bool
		/** Set if we use the `swift-process-invocation-bridge` launcher. */
		let forcedPreprendedPATH: FilePath?
		if usePATH {
			if case .some(.some(let p)) = customPATH {
				PATH = p
				isDefaultPATH = false
			} else {
				let PATHstr: String
				if case .some(.none) = customPATH {
					/* We use the default path: _PATH_DEFPATH */
					PATHstr = _PATH_DEFPATH
					isDefaultPATH = true
				} else {
					/* We use the PATH env var */
					let envPATHstr = getenv("PATH").flatMap{ String(cString: $0) }
					PATHstr = envPATHstr ?? _PATH_DEFPATH
					isDefaultPATH = (envPATHstr == nil)
				}
				PATH = PATHstr.split(separator: ":", omittingEmptySubsequences: false).map{ FilePath(String($0)) }
			}
		} else {
			PATH = []
			isDefaultPATH = false
		}
		
		let actualExecutablePath: FilePath
		if fileDescriptorsToSend.isEmpty {
			p.arguments = args
			actualExecutablePath = executable
			forcedPreprendedPATH = nil
			fdToSendFds = nil
		} else {
			let execBasePath = getenv(Constants.bridgePathEnvVarName).flatMap{ FilePath(String(cString: $0)) }
			if !usePATH {
				guard let execBasePath = execBasePath else {
					Conf.logger?.error("Cannot launch process and send its fd if \(Constants.bridgePathEnvVarName) is not set.")
					try cleanupAndThrow(Err.bridgePathEnvVarNotSet)
				}
				actualExecutablePath = execBasePath.appending(Constants.bridgeExecutableName)
				forcedPreprendedPATH = nil
			} else {
				actualExecutablePath = FilePath(Constants.bridgeExecutableName)
				forcedPreprendedPATH = execBasePath
			}
			
			/* The socket to send the fd.
			 * The tuple thingy _should_ be _in effect_ equivalent to the C version `int sv[2] = {-1, -1};`:
			 *  <https://forums.swift.org/t/guarantee-in-memory-tuple-layout-or-dont/40122>
			 * Stride and alignment should be the equal for CInt.
			 * Funnily, it seems to only work in debug compilation, not in release… */
//			var sv: (CInt, CInt) = (-1, -1) */
			let sv = UnsafeMutablePointer<CInt>.allocate(capacity: 2)
			sv.initialize(repeating: -1, count: 2)
			defer {sv.deallocate()}
#if canImport(Darwin)
			let sockDgram = SOCK_DGRAM
#else
			let sockDgram = Int32(SOCK_DGRAM.rawValue)
#endif
			guard socketpair(/*domain: */AF_UNIX, /*type: */sockDgram, /*protocol: */0, /*socket_vector: */sv) == 0 else {
				/* TODO: Throw a more informative error? */
				try cleanupAndThrow(Err.systemError(Errno(rawValue: errno)))
			}
			let fd0 = FileDescriptor(rawValue: sv.advanced(by: 0).pointee)
			let fd1 = FileDescriptor(rawValue: sv.advanced(by: 1).pointee)
			assert(fd0.rawValue != -1 && fd1.rawValue != -1)
			
			fdsToCloseAfterRun.insert(fd1)
			fdsToCloseInCaseOfError.insert(fd0)
			fdsToCloseInCaseOfError.insert(fd1)
			
			/* We must send the modified stdin in the list of file descriptors to send!
			 * (Before modifying p.standardInput…) */
			fileDescriptorsToSend[.standardInput] = (p.standardInput as? FileHandle).flatMap{ .init(rawValue: $0.fileDescriptor) }
			
			let cwd = FilePath(FileManager.default.currentDirectoryPath)
			if !cwd.isAbsolute {Conf.logger?.error("currentDirectoryPath is not abolute! Madness may ensue.", metadata: ["path": "\(cwd)"])}
			/* We make all paths absolute, and filter the ones containing colons. */
			let PATHstr = (!isDefaultPATH ? PATH.map{ cwd.pushing($0).string }.filter{ $0.firstIndex(of: ":") == nil }.joined(separator: ":") : nil)
			let PATHoption = PATHstr.flatMap{ ["--path", $0] } ?? []
			
			p.arguments = [usePATH ? "--use-path" : "--no-use-path"] + PATHoption + [executable.string] + args
			p.standardInput = FileHandle(fileDescriptor: fd1.rawValue, closeOnDealloc: false)
			fdToSendFds = fd0
		}
		
		let delayedSigations = try cleanupIfThrows{ try SigactionDelayer_Unsig.registerDelayedSigactions(signalsToProcess, handler: { (signal, handler) in
			Conf.logger?.debug("Executing signal handler action in ProcessInvocation.", metadata: ["signal": "\(signal)"])
			guard p.isRunning else {
				Conf.logger?.trace("Process is not running; forwarding signal directly.", metadata: ["signal": "\(signal)"])
				handler(true)
				return
			}
			
			let handling = signalHandling(signal)
			
			let signalForChildSucceeded: Bool
			if let signalForChild = handling.signalForChild {
				if handling.sendToProcessGroupOfChild {
					let pgid = getpgid(p.processIdentifier)
					signalForChildSucceeded = (killpg(pgid, signalForChild.rawValue) == 0)
				} else {
					signalForChildSucceeded = (kill(p.processIdentifier, signalForChild.rawValue) == 0)
				}
			} else {
				signalForChildSucceeded = true
			}
			
			guard signalForChildSucceeded else {
				Conf.logger?.notice("Failed sending signal to children; ignoring signal.", metadata: ["signal": "\(signal)"])
				return handler(false)
			}
			
			if handling.waitForChildDeathBeforeSendingToParent {
				p.waitUntilExit()
			}
			
			handler(handling.allowOnParent)
		}) }
		let signalCleanupHandler = {
			let errors = SigactionDelayer_Unsig.unregisterDelayedSigactions(Set(delayedSigations.values))
			for (signal, error) in errors {
				Conf.logger?.error("Cannot unregister delayed sigaction.", metadata: ["signal": "\(signal)", "error": "\(error)"])
			}
		}
		signalCleaningOnError = signalCleanupHandler
		
		let additionalTerminationHandler: @Sendable (Process) -> Void = { _ in
			Conf.logger?.debug("Called in termination handler of process.")
			if let fgPgIDSetInfo = fgPgIDSetInfo {
				/* Let’s revert the fg pg ID back to the original value. */
				Conf.logger?.debug("Setting pgrp of input fd back to original value.", metadata: ["fd": "\(fgPgIDSetInfo.destFd)", "value": "\(fgPgIDSetInfo.originalValue)"])
				if tcsetpgrp(fgPgIDSetInfo.destFd.rawValue, fgPgIDSetInfo.originalValue) != 0 && errno != ENOTTY {
					Conf.logger?.error("Failed setting foreground process group ID of controlling terminal of redirected stdin back to the original value.", metadata: ["error": "\(Errno(rawValue: errno))"])
				}
			}
			signalCleanupHandler()
			g.leave()
		}
#if canImport(eXtenderZ)
		XTZCheckedAddExtender(p, XcodeToolsProcessExtender(additionalTerminationHandler))
#else
		p.privateTerminationHandler = additionalTerminationHandler
#endif
		
		/* We used to enter the dispatch group in the registration handlers of the dispatch sources,
		 *  but we got races where the executable ended before the dispatch sources were even registered.
		 * So now we enter the group before launching the executable.
		 * We enter also once for the process launch (left in additional termination handler of the process). */
		countOfDispatchGroupLeaveInCaseOfError = outputFileDescriptors.count + 1
		for _ in 0..<countOfDispatchGroupLeaveInCaseOfError {
			g.enter()
		}
		
		Conf.logger?.info("Launching process\(fileDescriptorsToSend.isEmpty ? "" : " through swift-process-invocation-bridge").", metadata: ["command": .array(["\(executable)"] + args.map{ "\($0)" })])
		try cleanupIfThrows{
			let actualPATH = [forcedPreprendedPATH].compactMap{ $0 } + PATH
			func tryPaths(from index: Int, executableComponent: FilePath.Component) throws {
				do {
					let url = URL(fileURLWithPath: actualPATH[index].appending([executableComponent]).string)
					Conf.logger?.debug("Trying new executable path for launch.", metadata: ["path": "\(url.path)"])
					p.executableURL = url
					try p.run()
				} catch {
					let nserror = error as NSError
					switch (nserror.domain, nserror.code) {
						case (NSCocoaErrorDomain, NSFileNoSuchFileError) /* Apple platforms */,
							  (NSCocoaErrorDomain, CocoaError.Code.fileReadNoSuchFile.rawValue) /* Linux */:
							let nextIndex = actualPATH.index(after: index)
							if nextIndex < actualPATH.endIndex {
								try tryPaths(from: nextIndex, executableComponent: executableComponent)
							} else {
								throw error
							}
							
						default:
							throw error
					}
				}
			}
			if usePATH, !actualPATH.isEmpty, !actualExecutablePath.isAbsolute, actualExecutablePath.components.count == 1, let component = actualExecutablePath.components.last {
				try tryPaths(from: actualPATH.startIndex, executableComponent: component)
			} else {
				p.executableURL = URL(fileURLWithPath: actualExecutablePath.string)
				try p.run()
			}
			/* Decrease count of group leaves needed because now that the process is launched, its termination handler will be called. */
			countOfDispatchGroupLeaveInCaseOfError -= 1
			signalCleaningOnError = nil
			/* We send the fds to the child process.
			 * If this fails we fail the whole process invocation and kill the subprocess. */
			if !fileDescriptorsToSend.isEmpty {
				let fdToSendFds = fdToSendFds!
				do {
					try withUnsafeBytes(of: Int32(fileDescriptorsToSend.count), { bytes in
						guard try fdToSendFds.write(bytes) == bytes.count else {
							throw Err.internalError("Unexpected count of sent bytes to fdToSendFds")
						}
					})
					for (fdInChild, fdToSend) in fileDescriptorsToSend {
						try Self.send(fd: fdToSend.rawValue, destfd: fdInChild.rawValue, to: fdToSendFds.rawValue)
					}
				} catch {
					kill(p.processIdentifier, SIGKILL)
					try cleanupAndThrow(error)
				}
				/* All of the fds have been sent.
				 * Now if we get an error closing fds we log the error but do not fail the whole invocation. */
				Conf.logger?.trace("Closing fd to send fds.", metadata: ["fd": "\(fdToSendFds)"])
				do    {try fdToSendFds.close()}
				catch {Conf.logger?.error("Failed closing fd to send fds.", metadata: ["error": "\(error)", "fd": "\(fdToSendFds)"])}
				Conf.logger?.trace("Closing sent fds.", metadata: ["fds": .array(fileDescriptorsToSend.values.filter{ $0 != .standardInput }.map{ "\($0)" })])
				fileDescriptorsToSend.values.forEach{
					if $0 != .standardInput {
						do    {try $0.close()}
						catch {Conf.logger?.error("Failed closing sent fd.", metadata: ["error": "\(error)", "fd": "\($0)"])}
					}
				}
				fdsToCloseInCaseOfError.remove(fdToSendFds) /* Not really useful there cannot be any more errors from there. */
			}
		}
		/* The executable is now launched.
		 * We must not fail after this, so we wrap the rest of the function in a non-throwing block. */
		return {
			if let fgPgIDSetInfo = fgPgIDSetInfo {
				let pgid = getpgid(p.processIdentifier)
				if pgid == -1 {
					Conf.logger?.error("Failed retrieving the process group ID of the child process.", metadata: ["error": "\(Errno(rawValue: errno))"])
				} else if tcsetpgrp(fgPgIDSetInfo.destFd.rawValue, pgid) != 0 && errno != ENOTTY {
					Conf.logger?.error("Failed setting the foreground group ID to the child process group ID.", metadata: ["error": "\(Errno(rawValue: errno))"])
				}
			}
			fdsToCloseAfterRun.forEach{
				do    {try $0.close()}
				catch {Conf.logger?.error("Failed closing a file descriptor.", metadata: ["error": "\(error)", "fd": "\($0)"])}
				fdsToCloseInCaseOfError.remove($0)
			}
			
			for fd in outputFileDescriptors {
				let streamReader = FileDescriptorReader(stream: fd, bufferSize: 1024, bufferSizeIncrement: 512)
				streamReader.underlyingStreamReadSizeLimit = 0
				
				let streamSource = DispatchSource.makeReadSource(fileDescriptor: fd.rawValue, queue: Self.streamQueue)
				streamSource.setCancelHandler{
					_ = try? fd.close()
					g.leave()
				}
				streamSource.setEventHandler{
					/* `source.data`: see doc of dispatch_source_get_data in objc */
					/* `source.mask`: see doc of dispatch_source_get_mask in objc (is always 0 for read source) */
					Self.handleProcessOutput(
						streamSource: streamSource,
						outputHandler: { lineOrError, signalEOI in actualOutputHandler(lineOrError.map{ RawLineWithSource(line: $0.0, eol: $0.1, fd: fdRedirects[fd] ?? fd) }, signalEOI, p) },
						lineSeparators: lineSeparators,
						streamReader: streamReader,
						estimatedBytesAvailable: streamSource.data,
						platformSpecificInfo: platformSpecificInfo
					)
				}
				streamSource.activate()
			}
			
			return (p, g)
		}()
	}
	
	public struct Iterator : AsyncIteratorProtocol {
		
		public typealias Element = RawLineWithSource
		
		public mutating func next() async throws -> RawLineWithSource? {
			if outputIterator == nil {
				let outputSequence = AsyncThrowingStream<RawLineWithSource, Error>{ continuation in
					do {
						let (p, g) = try invocation.invoke{ result, _, _ in
							continuation.yield(with: result)
						}
						process = p
						g.notify(queue: ProcessInvocation.streamQueue, execute: {
							continuation.finish(throwing: nil)
						})
					} catch {
						continuation.finish(throwing: error)
					}
				}
				outputIterator = outputSequence.makeAsyncIterator()
			}
			if let n = try await outputIterator!.next() {
				return n
			} else {
				/* If there are no more elements, the process has ended. */
				let p = process!
				try ProcessInvocation.checkTermination(
					expectedTerminations: invocation.expectedTerminations,
					terminationStatus: p.terminationStatus, terminationReason: p.terminationReason
				)
				return nil
			}
		}
		
		internal init(invocation: ProcessInvocation) {
			self.invocation = invocation
		}
		
		private var process: Process?
		
		private let invocation: ProcessInvocation
		private var outputIterator: AsyncThrowingStream<RawLineWithSource, Error>.Iterator?
		
	}
	
	/* ***************
	   MARK: - Private
	   *************** */
	
#if canImport(Darwin)
	private typealias StreamReadPlatformSpecificInfo = Void
#else
	private struct StreamReadPlatformSpecificInfo {
		var masterPTFileDescriptors: Set<FileDescriptor> = []
	}
#endif
	
	private static let streamQueue = DispatchQueue(label: "com.xcode-actions.process")
	
	private static func checkTermination(expectedTerminations: [(Int32, Process.TerminationReason)]?, terminationStatus: Int32, terminationReason: Process.TerminationReason) throws {
		guard let expectedTerminations = expectedTerminations else {
			return
		}
		guard expectedTerminations.contains(where: { $0.0 == terminationStatus && $0.1 == terminationReason }) else {
			throw Err.unexpectedSubprocessExit(terminationStatus: terminationStatus, terminationReason: terminationReason)
		}
	}
	
	private static func setRequireNonBlockingIO(on fd: FileDescriptor, logChange: Bool) throws {
		let curFlags = fcntl(fd.rawValue, F_GETFL)
		guard curFlags != -1 else {
			throw Err.systemError(Errno(rawValue: errno))
		}
		
		let newFlags = curFlags | O_NONBLOCK
		guard newFlags != curFlags else {
			/* Nothing to do */
			return
		}
		
		if logChange {
			/* We only log for fd that were not ours */
			Conf.logger?.warning("Setting O_NONBLOCK option on fd.", metadata: ["fd": "\(fd)"])
		}
		guard fcntl(fd.rawValue, F_SETFL, newFlags) != -1 else {
			throw Err.systemError(Errno(rawValue: errno))
		}
	}
	
	private static func removeRequireNonBlockingIO(on fd: FileDescriptor) throws {
		let curFlags = fcntl(fd.rawValue, F_GETFL)
		guard curFlags != -1 else {
			throw Err.systemError(Errno(rawValue: errno))
		}
		
		let newFlags = curFlags & ~O_NONBLOCK
		guard newFlags != curFlags else {
			/* Nothing to do */
			return
		}
		
		guard fcntl(fd.rawValue, F_SETFL, newFlags) != -1 else {
			throw Err.systemError(Errno(rawValue: errno))
		}
	}
	
	private static func handleProcessOutput(
		streamSource: DispatchSourceRead,
		outputHandler: @escaping (Result<(Data, Data), Error>, () -> Void) -> Void,
		lineSeparators: LineSeparators,
		streamReader: GenericStreamReader,
		estimatedBytesAvailable: UInt,
		platformSpecificInfo: StreamReadPlatformSpecificInfo
	) {
		do {
			let toRead = Int(Swift.min(Swift.max(estimatedBytesAvailable, 1), UInt(Int.max)))
#if canImport(Darwin)
			/* We do not need to check the number of bytes actually read.
			 * If EOF was reached (nothing was read),
			 *  the stream reader will remember it, and
			 *  the readLine method will properly return nil without even trying to read from the stream.
			 * Which matters, because we forbid the reader from reading from the underlying stream (except in these read). */
			Conf.logger?.trace("Reading output stream.", metadata: ["approximate_bytes_count": "\(toRead)", "source": "\(streamReader.sourceStream)"])
			_ = try streamReader.readStreamInBuffer(size: toRead, allowMoreThanOneRead: false, bypassUnderlyingStreamReadSizeLimit: true)
#else
			Conf.logger?.trace("In libdispatch callback.", metadata: ["source": "\(streamReader.sourceStream)"])
			/* On Linux we have to use non-blocking IO for some reason.
			 * I’d say it’s a libdispatch bug, but I’m not sure.
			 * <https://stackoverflow.com/questions/39173429#comment121697690_46142976> */
			let read: () throws -> Int = {
				Conf.logger?.trace("Reading output stream.", metadata: ["approximate_bytes_count": "\(toRead)", "source": "\(streamReader.sourceStream)"])
				return try streamReader.readStreamInBuffer(size: toRead, allowMoreThanOneRead: false, bypassUnderlyingStreamReadSizeLimit: true)
			}
			let processError: (Error) -> Result<Int, Error> = { e in
				if case Errno.resourceTemporarilyUnavailable = e {
					Conf.logger?.trace("Masking resource temporarily unavailable error.", metadata: ["source": "\(streamReader.sourceStream)"])
					return .success(0)
				}
				if case Errno.ioError = e, platformSpecificInfo.masterPTFileDescriptors.contains(streamReader.sourceStream as! FileDescriptor) {
					/* See <https://stackoverflow.com/a/72159292> for more info about why we do this.
					 * The link above says the I/O error occurs when every slave is closed, aka. when the process has died.
					 * Initially we checked whether the process was running and if it were we did not convert the I/O error to EOF,
					 *  but we had races where the process had effectively finished running but isRunning still returned true.
					 * (Interestingly the check worked when the verbose mode was present but not when it was not.)
					 * Now we only check for a master pt fd and assume the I/O error is EOF… */
					Conf.logger?.trace("Converting I/O error to EOF.", metadata: ["source": "\(streamReader.sourceStream)"])
					streamReader.readSizeLimit = streamReader.currentStreamReadPosition - streamReader.currentReadPosition
					return .success(0)
				}
				return .failure(e)
			}
			while try Result(catching: read).flatMapError(processError).get() >= toRead {/*nop*/}
#endif
			
			let readLine: () throws -> (Data, Data)?
			switch lineSeparators {
				case .newLine(let unix, let legacyMacOS, let windows):
					readLine = {
						try streamReader.readLine(allowUnixNewLines: unix, allowLegacyMacOSNewLines: legacyMacOS, allowWindowsNewLines: windows)
					}
					
				case .customCharacters(let set):
					readLine = {
						let ret = try streamReader.readData(upTo: set.map{ Data([$0]) }, matchingMode: .shortestDataWins, failIfNotFound: false, includeDelimiter: false)
						_ = try streamReader.readData(size: ret.delimiter.count, allowReadingLess: false)
						guard !ret.data.isEmpty || !ret.delimiter.isEmpty else {
							return nil
						}
						return ret
					}
			}
			while let (lineData, eolData) = try readLine() {
				var continueStream = true
				outputHandler(.success((lineData, eolData)), { continueStream = false })
				guard continueStream else {
					Conf.logger?.debug("Client is not interested in stream anymore; cancelling read stream.", metadata: ["source": "\(streamReader.sourceStream)"])
					streamSource.cancel()
					return
				}
			}
			/* We have read all the stream, we can stop. */
			Conf.logger?.debug("End of stream reached (or eoi signalled); cancelling read stream.", metadata: ["source": "\(streamReader.sourceStream)"])
			streamSource.cancel()
			
		} catch StreamReaderError.streamReadForbidden {
			Conf.logger?.trace("Error reading stream: read forbidden (this is normal).", metadata: ["source": "\(streamReader.sourceStream)"])
			
		} catch {
			Conf.logger?.warning("Error reading stream.", metadata: ["source": "\(streamReader.sourceStream)", "error": "\(error)"])
			outputHandler(.failure(error), { })
			/* We stop the stream at first unknown error. */
			streamSource.cancel()
		}
	}
	
	/* Based on <https://stackoverflow.com/a/28005250> (last variant). */
	private static func send(fd: CInt, destfd: CInt, to socket: CInt) throws {
		var fd = fd /* A var because we use a pointer to it at some point, but never actually modified. */
		let sizeOfFd = MemoryLayout.size(ofValue: fd) /* We’ll need this later. */
		let sizeOfDestfd = MemoryLayout.size(ofValue: destfd) /* We’ll need this later. */
		
		var msg = msghdr()
		
		/* We’ll place the destination fd (a simple CInt) in an iovec. */
		let iovBase = UnsafeMutablePointer<CInt>.allocate(capacity: 1)
		defer {iovBase.deallocate()}
		iovBase.initialize(to: destfd)
		
		let ioPtr = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
		defer {ioPtr.deallocate()}
		ioPtr.initialize(to: iovec(iov_base: iovBase, iov_len: sizeOfDestfd))
		
		msg.msg_iov = ioPtr
		msg.msg_iovlen = 1
		
		/* Ancillary data. This is where we send the actual fd. */
		let buf = UnsafeMutableRawPointer.allocate(byteCount: SPI_CMSG_SPACE(sizeOfFd), alignment: MemoryLayout<cmsghdr>.alignment)
		defer {buf.deallocate()}
		
#if canImport(Darwin)
		msg.msg_control = UnsafeMutableRawPointer(buf)
		msg.msg_controllen = socklen_t(SPI_CMSG_SPACE(sizeOfFd))
#else
		msg.msg_control = UnsafeMutableRawPointer(buf)
		msg.msg_controllen = Int(SPI_CMSG_SPACE(sizeOfFd))
#endif
		
		guard let cmsg = SPI_CMSG_FIRSTHDR(&msg) else {
			throw Err.internalError("CMSG_FIRSTHDR returned nil.")
		}
		
#if canImport(Darwin)
		cmsg.pointee.cmsg_type = SCM_RIGHTS
		cmsg.pointee.cmsg_level = SOL_SOCKET
#else
		cmsg.pointee.cmsg_type = Int32(SCM_RIGHTS)
		cmsg.pointee.cmsg_level = SOL_SOCKET
#endif
		
#if canImport(Darwin)
		cmsg.pointee.cmsg_len = socklen_t(SPI_CMSG_LEN(sizeOfFd))
#else
		cmsg.pointee.cmsg_len = Int(SPI_CMSG_LEN(sizeOfFd))
#endif
		memmove(SPI_CMSG_DATA(cmsg), &fd, sizeOfFd)
		
		guard sendmsg(socket, &msg, /*flags: */0) != -1 else {
			throw Err.systemError(Errno(rawValue: errno))
		}
		Conf.logger?.debug("Sent fd through socket to child process", metadata: ["fd": "\(fd)"])
	}
	
}



#if canImport(eXtenderZ)

class XcodeToolsProcessExtender : NSObject, SPITaskExtender {
	
	let additionalCompletionHandler: (Process) -> Void
	
	init(_ completionHandler: @escaping (Process) -> Void) {
		self.additionalCompletionHandler = completionHandler
	}
	
	func prepareObject(forExtender object: NSObject) -> Bool {return true}
	func prepareObjectForRemoval(ofExtender object: NSObject) {/*nop*/}
	
}

#else

/**
 A subclass of Process whose termination handler is overridden, in order for XcodeTools
  to set its own termination handler and
  still let clients use it. */
private class XcodeToolsProcess : Process, @unchecked Sendable {
	
#if compiler(>=6)
	typealias TerminationHandler = (@Sendable (Process) -> Void)
#else
	typealias TerminationHandler = ((Process) -> Void)
#endif
	
	var privateTerminationHandler: TerminationHandler? {
		didSet {updateTerminationHandler()}
	}
	
	override init() {
		super.init()
		
		publicTerminationHandler = super.terminationHandler
		updateTerminationHandler()
	}
	
	deinit {
		Conf.logger?.trace("Deinit of an XcodeToolsProcess")
	}
	
	override var terminationHandler: TerminationHandler? {
		get {super.terminationHandler}
		set {publicTerminationHandler = newValue; updateTerminationHandler()}
	}
	
	private var publicTerminationHandler: TerminationHandler?
	
	/**
	 Sets super’s terminationHandler to nil if both private and public termination handlers are nil, otherwise set it to call them. */
	private func updateTerminationHandler() {
		if privateTerminationHandler == nil && publicTerminationHandler == nil {
			super.terminationHandler = nil
		} else {
			super.terminationHandler = { process in
				(process as! XcodeToolsProcess).privateTerminationHandler?(process)
				(process as! XcodeToolsProcess).publicTerminationHandler?(process)
			}
		}
	}
	
}

#endif
