import GoogleGatewayAuth
import Foundation
import GmailGatewayCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .gmail, role: "sender")

let result = await GmailGatewayCLI(mode: .directSender, authPolicy: .persistent(requiredAccessMode: .readSend)).runPersistent(
    arguments: gatewayInvocation.arguments,
    environment: gatewayInvocation.environment
)

if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}

exit(gatewayInvocation.complete(exitCode: result.exitCode))
