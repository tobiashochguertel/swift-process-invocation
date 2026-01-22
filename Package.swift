// swift-tools-version:5.5
import PackageDescription

import Foundation


/* Detect if we need the eXtenderZ.
 * If we do (on Apple platforms where the non-public Foundation implementation is used), the eXtenderZ should be able to be imported.
 * See Process+Utils for reason why we use the eXtenderZ. */
let useXtenderZ = (NSStringFromClass(Process().classForCoder) != "NSTask")
/* Do we need the _GNU_SOURCE exports? This allows using execvpe on Linux. */
#if canImport(Darwin)
let needsGNUSourceExports = false
#else
let needsGNUSourceExports = true
#endif

let isXcode = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]?.lowercased().contains("xcode") ?? false
let executableName = isXcode ? "ProcessInvocationBridge" : "swift-process-invocation-bridge"


let package = Package(
	name: "swift-process-invocation",
	platforms: [.macOS(.v11)],
	products: [
		.library(name: "ProcessInvocation", targets: ["ProcessInvocation"]),
		/* A launcher for forwarding fds when needed. */
		.executable(name: executableName, targets: ["ProcessInvocationBridge"])
	],
	dependencies: {
		var res = [Package.Dependency]()
		res.append(.package(url: "https://github.com/apple/swift-argument-parser.git",         from: "1.2.2"))
		res.append(.package(url: "https://github.com/apple/swift-log.git",                     from: "1.5.2"))
		res.append(.package(url: "https://github.com/apple/swift-system.git",                  from: "1.0.0")) /* We’re aware of the existence of System on macOS. After some thinking/research, we decided to agree with <https://forums.swift.org/t/50719/5>. */
		res.append(.package(url: "https://github.com/Frizlab/stream-reader.git",               from: "3.6.1"))
		res.append(.package(url: "https://github.com/Frizlab/UnwrapOrThrow.git",               from: "1.0.1"))
		res.append(.package(url: "https://github.com/xcode-actions/clt-logger.git",            from: "1.0.0"))
		res.append(.package(url: "https://github.com/xcode-actions/swift-signal-handling.git", .upToNextMinor(from: "1.1.3")))
		if useXtenderZ {
			res.append(.package(url: "https://github.com/Frizlab/eXtenderZ.git",                from: "2.0.0"))
		}
		return res
	}(),
	targets: {
		var res = [Target]()
		
		res.append(.target(name: "ProcessInvocation", dependencies: {
			var res = [Target.Dependency]()
			res.append(.product(name: "Logging",        package: "swift-log"))
			res.append(.product(name: "SignalHandling", package: "swift-signal-handling"))
			res.append(.product(name: "StreamReader",   package: "stream-reader"))
			res.append(.product(name: "UnwrapOrThrow",  package: "UnwrapOrThrow"))
			res.append(.product(name: "SystemPackage",  package: "swift-system"))
			res.append(.target(name: "CMacroExports"))
			if useXtenderZ {
				res.append(.product(name: "eXtenderZ-static", package: "eXtenderZ"))
				res.append(.target(name: "CNSTaskHelptender"))
			}
			if needsGNUSourceExports {
				res.append(.target(name: "CGNUSourceExports"))
			}
			/* The ProcessInvocation depends (indirectly) on the bridge. */
			res.append(.target(name: "ProcessInvocationBridge"))
			return res
		}()))
		
		res.append(.executableTarget(name: "ProcessInvocationBridge", dependencies: {
			var res = [Target.Dependency]()
			res.append(.product(name: "ArgumentParser", package: "swift-argument-parser"))
			res.append(.product(name: "CLTLogger",      package: "clt-logger"))
			res.append(.product(name: "Logging",        package: "swift-log"))
			res.append(.product(name: "StreamReader",   package: "stream-reader"))
			res.append(.product(name: "SystemPackage",  package: "swift-system"))
			res.append(.target(name: "CMacroExports"))
			if needsGNUSourceExports {
				res.append(.target(name: "CGNUSourceExports"))
			}
			return res
		}()))
		
		res.append(.testTarget(name: "ProcessInvocationTests", dependencies: {
			var res = [Target.Dependency]()
			res.append(.target(name: "ProcessInvocation")) /* <- Tested package */
			res.append(.product(name: "CLTLogger",     package: "clt-logger"))
			res.append(.product(name: "Logging",       package: "swift-log"))
			res.append(.product(name: "StreamReader",  package: "stream-reader"))
			res.append(.product(name: "SystemPackage",  package: "swift-system"))
			if needsGNUSourceExports {
				res.append(.target(name: "CGNUSourceExportsForTests"))
			}
			return res
		}()))
		
		/* Some complex macros exported as functions to be used in Swift. */
		res.append(.target(name: "CMacroExports"))
		if useXtenderZ {
			res.append(.target(name: "CNSTaskHelptender", dependencies: [.product(name: "eXtenderZ-static", package: "eXtenderZ")]))
		}
		if needsGNUSourceExports {
			res.append(.target(name: "CGNUSourceExports"))
			res.append(.target(name: "CGNUSourceExportsForTests"))
		}
		
		/* Some manual tests for stdin redirect behavior. */
		res.append(.executableTarget(name: "ManualTests", dependencies: [
			.target(name: "ProcessInvocation"), /* <- Tested package */
			.product(name: "CLTLogger",    package: "clt-logger"),
			.product(name: "Logging",      package: "swift-log"),
			.product(name: "StreamReader", package: "stream-reader"),
		]))
		
		return res
	}()
)
