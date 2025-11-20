import Foundation

import CLTLogger
import Logging
import ProcessInvocation
import SystemPackage



LoggingSystem.bootstrap(CLTLogger.init, metadataProvider: nil)
let logger = {
	var ret = Logger(label: "com.xcode-actions.manual-process-invocation-tests")
	ret.logLevel = .trace
	return ret
}()
ProcessInvocationConfig.logger = logger


do {
	while true {
		_ = try await ProcessInvocation(
			"bash", "-c", "echo ok1; sleep 0.1; echo ok2; sleep 0.1; echo ok3; sleep 0.1",
			stdinRedirect: .none(setFgPgID: true),
			stdoutRedirect: .none,
			stderrRedirect: .none,
			signalHandling: { signal in .init(signalForChild: signal, allowOnParent: false) }
		).invokeAndGetRawOutput()
	}
} catch {
	logger.warning("Process invocation failed.", metadata: ["error": "\(error)"])
}
