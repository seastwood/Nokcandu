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

    /// The Apple Developer team whose Developer ID builds may update this app (Info.plist NokcanduTrustedTeamID,
    /// written at build time from NOKCANDU_TEAM_ID). A self-signed release that names it lets the first Developer ID
    /// release update it in place, and Developer ID releases keep updating across certificate renewals.
    public static var trustedTeamID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "NokcanduTrustedTeamID") as? String).flatMap(validTeam)
    }
    static func validTeam(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 10 && t.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } ? t : nil
    }
    /// Signed with Developer ID by `team` and notarized by Apple.
    public static func requirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\" and notarized"
    }
    public static func isTrustedDeveloperID(_ app: URL, team: String) -> Bool {
        var code: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement(team: team) as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req) == errSecSuccess
    }

    /// Throws unless `update` may replace `current`.
    public static func check(update: URL, current: URL) throws {
        if let team = trustedTeamID, isTrustedDeveloperID(update, team: team) { return }
        switch verdict(current: certificate(of: current), update: certificate(of: update)) {
        case .sameSigner, .developmentBuild: return
        case .unsigned:
            throw NokError("This update isn't signed by Nokcandu's signer (it names no signer at all), so it wasn't installed. If you trust it, download it from the Releases page and replace the app yourself.")
        case .differentSigner:
            throw NokError("This update is signed by someone other than the signer of the Nokcandu you're running, so it wasn't installed. If Nokcandu announced a change of signing, download the new version from the Releases page and replace the app yourself.")
        }
    }
}
