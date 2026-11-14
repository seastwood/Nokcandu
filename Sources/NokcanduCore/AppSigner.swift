// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Who signed an app, for the updater: an update must come from the signer of the app that is running.
/// The download's SHA-256 (published by GitHub) and an intact signature say the file arrived as it was
/// uploaded; they don't say who made it. Without this check, a tampered release would have been installed.
public enum AppSigner {
    /// The certificate an app was signed with (its leaf certificate, DER), or nil for an ad-hoc signature
    /// (a development build), which names no signer.
    public static func certificate(of app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    public enum Verdict: Equatable { case sameSigner, developmentBuild, differentSigner, unsigned }
    /// `current`: the running app's certificate; `update`: the new app's.
    public static func verdict(current: Data?, update: Data?) -> Verdict {
        guard let current else { return .developmentBuild }        // nothing to compare with: as before
        guard let update else { return .unsigned }
        return current == update ? .sameSigner : .differentSigner
    }

    /// Throws unless `update` may replace `current`.
    public static func check(update: URL, current: URL) throws {
        switch verdict(current: certificate(of: current), update: certificate(of: update)) {
        case .sameSigner, .developmentBuild: return
        case .unsigned:
            throw NokError("This update isn't signed by Nokcandu's signer (it names no signer at all), so it wasn't installed. If you trust it, download it from the Releases page and replace the app yourself.")
        case .differentSigner:
            throw NokError("This update is signed by someone other than the signer of the Nokcandu you're running, so it wasn't installed. If Nokcandu announced a change of signing, download the new version from the Releases page and replace the app yourself.")
        }
    }
}
