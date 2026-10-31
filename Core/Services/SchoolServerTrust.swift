import Foundation
import Security

/// 學校主機（`*.niu.edu.tw`）的 TLS 信任：在系統根憑證之外，再信任 TWCA CYBER Root CA。
///
/// 學校的 `*.niu.edu.tw` 憑證鏈到 TWCA CYBER Root CA，這張根憑證不在 Apple 的信任清單裡。
/// 多數學校主機會一併送出由 TWCA Global Root CA（Apple 有內建）交叉簽署的版本，所以能連線；
/// `ccsys1.niu.edu.tw`（新版 SSO）沒有送，TLS 驗證因此失敗：登入頁之後的憑證驗證、
/// token 更新與 GUID 交換都會中斷。
///
/// 系統本身驗證通過的連線一律交回預設處理；只有學校主機在系統驗證失敗時，才加上這張根憑證
/// 重新驗證（仍保留系統根憑證，主機名稱檢查不變）。學校補上交叉憑證後這段不會再被用到。
enum SchoolServerTrust {
    /// 給連到學校主機的 URLSession 使用：`URLSession.shared` 的 task delegate，或自建 session 的 delegate。
    nonisolated static let delegate = Delegate()

    nonisolated final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            SchoolServerTrust.handle(challenge)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            SchoolServerTrust.handle(challenge)
        }
    }

    /// URLSession delegate 用，在 session 的佇列上同步驗證，不會在主執行緒。
    nonisolated static func handle(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = schoolTrust(challenge),
              !SecTrustEvaluateWithError(trust, nil) else { return (.performDefaultHandling, nil) }
        addCyberRoot(to: trust)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// WKNavigationDelegate 用，在主執行緒呼叫；驗證以非同步方式進行，不阻塞畫面。
    @MainActor
    static func respond(
        to challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = schoolTrust(challenge) else { return (.performDefaultHandling, nil) }
        if await evaluate(trust) { return (.performDefaultHandling, nil) }
        addCyberRoot(to: trust)
        guard await evaluate(trust) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    nonisolated static func isSchoolHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "niu.edu.tw" || host.hasSuffix(".niu.edu.tw")
    }

    nonisolated private static func schoolTrust(_ challenge: URLAuthenticationChallenge) -> SecTrust? {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              isSchoolHost(space.host) else { return nil }
        return space.serverTrust
    }

    /// 主執行緒上呼叫；SecTrustEvaluateAsyncWithError 要求在傳入的佇列上呼叫。
    @MainActor
    private static func evaluate(_ trust: SecTrust) async -> Bool {
        await withCheckedContinuation { continuation in
            SecTrustEvaluateAsyncWithError(trust, .main) { _, trusted, _ in
                continuation.resume(returning: trusted)
            }
        }
    }

    nonisolated private static func addCyberRoot(to trust: SecTrust) {
        guard let data = Data(base64Encoded: cyberRootDER, options: .ignoreUnknownCharacters),
              let root = SecCertificateCreateWithData(nil, data as CFData) else { return }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        // 保留系統根憑證，只是多信任這一張。
        SecTrustSetAnchorCertificatesOnly(trust, false)
    }

    /// TWCA CYBER Root CA（DER，base64），有效至 2047-11-22。
    /// SHA-256：3F63BB2814BE174EC8B6439CF08D6D56F0B7C405883A5648A334424D6B3EC558
    nonisolated private static let cyberRootDER = """
        MIIFjTCCA3WgAwIBAgIQQAE0jMIAAAAAAAAAATzyxjANBgkqhkiG9w0BAQwFADBQMQswCQYDVQQG
        EwJUVzESMBAGA1UEChMJVEFJV0FOLUNBMRAwDgYDVQQLEwdSb290IENBMRswGQYDVQQDExJUV0NB
        IENZQkVSIFJvb3QgQ0EwHhcNMjIxMTIyMDY1NDI5WhcNNDcxMTIyMTU1OTU5WjBQMQswCQYDVQQG
        EwJUVzESMBAGA1UEChMJVEFJV0FOLUNBMRAwDgYDVQQLEwdSb290IENBMRswGQYDVQQDExJUV0NB
        IENZQkVSIFJvb3QgQ0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDG+Moe2Qkgfh1s
        Ts6P40czRJzHyWmqOlt47nDSkvgEs1JSHWdyKKHfi12VCv7qze33Kc7wb3+szT3vsxxFavcokPFh
        V8UMxKNQXd7UtcsZyoC5dc4pztKFIuwCY8xEMCDa6pFbVuYdHNWdZsc/34bKS1PE2Y2yHer43CdT
        o0fhYcx9tbD47nORxc5zb87uEB8aBs/pJ2DFTxnk684iJkXXYJndzk834H/nY62wuFm40AZoNWDT
        Nq5xQwTxaWV4fPMf88oon1oglWa0zbfuj3ikRRjpJi+NmykosaS3Om251Bw4ckVYsV7r8Cibt4LK
        /c/WMw+f+5eesRycnupfXtuq3VTpMCEobY5583WSjCb+3MX2w7DfRFlDo7YDKPYIMKoNM+HvnKkH
        IuNZW0CP2oi3aQiotyMuRAlZN1vH4xfyIutuOVLF3lSnmMlLIJXcRolftBL5hSmO68gnFSDAS9TM
        fAxsNAwmmyYxpjyn9tnQS6Jk/zuZQXLB4HCX8SS7K8R0IrGsayIyJNN4KsDAoS/xUgXJP+92ZuJF
        2A09rZXIx4kmyA+upwMu+8Ff+iDhcK2wZSA3M2Cw1a/XDBzCkHDXShi8fgGwsOsVHkQGzaRP6AzR
        wyAQ4VRlnrZR0Bp2a0JaWHY06rc3Ga4udfmW5cFZ95RXKSWNOkyrTZpB0F8mAwIDAQABo2MwYTAO
        BgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBSdhWEUfMFib5do5E83
        QOGt4A1WNzAdBgNVHQ4EFgQUnYVhFHzBYm+XaORPN0DhreANVjcwDQYJKoZIhvcNAQEMBQADggIB
        AGSPesRiDrWIzLjHhg6hShbNcAu3p4ULs3a2D6f/CIsLJc+o1IN1KriWiLb73y0ttGlTITVX1olN
        c79pj3CjYcya2x6a4CD4bLubIp1dhDGaLIrdaqHXKGnK/nZVekZn68xDiBaiA9a5F/gZbG0jAn/x
        X9AKKSM70aoK7akXJlQKTcKlTfjF/biBzysseKNnTKkHmvPfXvt89YnNdJdhEGoHK4Fa0o635yDR
        IG4kqIQnoVesqlVYL9zZyvpoBJ7tRCT5dEA7IzOrg1oYJkK2bVS1FmAwbLGg+LhBoF1JSdJlBTrq
        /p1hvIbZv97Tujqxf36SNI7JAG7cmL3c7IAFrQI932XtCwP39xaEBDG6k5TY8hL4iuO/Qq+n1M0R
        FxbIQh0UqEL20kCGoE8jypZFVmAGzbdVAaYBlGX+bgUJurSkquLvWL69J1bY73NxW0Qz8ppy6rBe
        Pm6pUlvscG21h483XjyMnM7k8M4MZ0HMzvaAq07MTFb1wWFZk7Q+ptq4NxKfKjLji7gh7MMrZQzv
        It6IKTtM1/r+t+FHvpw+PoP7UV31aPcuIYXcv/Fa4nzXxeSDwWrruoBa3lwtcHb4yOWHh8qgnaHl
        IhInD0Q9HWzq1MKLL295q39QpsQZp6F6t5b5wR9iWqJDB0BeJsas7a5wFsWqynKKTbDPAYsDP27X
        """
}
