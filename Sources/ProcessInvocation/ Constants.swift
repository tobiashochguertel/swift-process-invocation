import Foundation

import Logging



public enum ProcessInvocationConstants {
	
	public static let bridgePathEnvVarName: String = "SWIFTPROCESSINVOCATION_BRIDGE_PATH"
	/* This logic is duplicated in the bridge. */
#if Xcode
	public static let bridgeExecutableName: String = "ProcessInvocationBridge"
#else
	public static let bridgeExecutableName: String = "swift-process-invocation-bridge"
#endif
	
}

typealias Constants = ProcessInvocationConstants
