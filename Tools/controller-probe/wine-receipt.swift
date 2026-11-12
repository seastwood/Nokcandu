// Run a receipt-only Windows probe using the app's real Wine environment.
// Logs are local and temporary; probe sources must exclude account/device IDs.
import Foundation
import NokcanduCore
@main struct Receipt {
 static func main() throws {
  guard CommandLine.arguments.count >= 4 else { return }
  let contents=URL(fileURLWithPath:CommandLine.arguments[1])
  var env=WineTools.environment(contents:contents)
  if let prefix=ProcessInfo.processInfo.environment["NOK_RECEIPT_PREFIX"] { env["WINEPREFIX"]=prefix;env["DYLD_INSERT_LIBRARIES"]=nil }
  env["WINEDEBUG"]="-all"
  let log=URL(fileURLWithPath:CommandLine.arguments[2])
  _=FileManager.default.createFile(atPath:log.path,contents:nil)
  let handle=try FileHandle(forWritingTo:log)
  let process=Process();process.executableURL=contents.appendingPathComponent("SharedSupport/wine/bin/wine")
  process.arguments=Array(CommandLine.arguments.dropFirst(3));process.environment=env
  process.standardInput=FileHandle.nullDevice;process.standardOutput=handle;process.standardError=handle
  try process.run();process.waitUntilExit();try handle.close()
  print("Receipt exit=\(process.terminationStatus); mode=\(Controllers.mode(contents:contents).rawValue); profileDriver=\(PadProfiles.driverInUse(contents:contents))")
 }
}
