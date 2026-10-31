#!/usr/bin/env python3
"""Check the TWCA CYBER Root CA trust for school hosts, offline and without Keychain."""
from pathlib import Path
import base64
import hashlib
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
trust = (root / "Core/Services/SchoolServerTrust.swift").read_text()

# The bundled root is exactly TWCA CYBER Root CA.
FINGERPRINT = "3f63bb2814be174ec8b6439cf08d6d56f0b7c405883a5648a334424d6b3ec558"
block = trust[trust.index('cyberRootDER = """') + len('cyberRootDER = """'):]
der = base64.b64decode(re.sub(r"\s", "", block[:block.index('"""')]))
assert hashlib.sha256(der).hexdigest() == FINGERPRINT, "Bundled root is not TWCA CYBER Root CA"
assert FINGERPRINT.upper() in trust, "Doc comment fingerprint must match the bundled root"

# The intermediate ccsys1 sends (public; valid until 2033-02-23) is signed by
# that root, so trusting it completes the chain the server leaves short.
INTERMEDIATE = """-----BEGIN CERTIFICATE-----
MIIG1DCCBLygAwIBAgIQQAE0sE8AAAAAAAAAA+MkrDANBgkqhkiG9w0BAQwFADBQ
MQswCQYDVQQGEwJUVzESMBAGA1UEChMJVEFJV0FOLUNBMRAwDgYDVQQLEwdSb290
IENBMRswGQYDVQQDExJUV0NBIENZQkVSIFJvb3QgQ0EwHhcNMjMwMjIzMDcyMjI0
WhcNMzMwMjIzMTU1OTU5WjBhMQswCQYDVQQGEwJUVzESMBAGA1UEChMJVEFJV0FO
LUNBMRMwEQYDVQQLEwpTU0wgU3ViLUNBMSkwJwYDVQQDEyBUV0NBIFNTTCBDZXJ0
aWZpY2F0aW9uIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
ggIBAMquxiSlMrxfOO29yqxCo/BIYBswnE7snZnuZDPcx8N9WhOdNGDsF024VjXK
nXoVaZBcv56eFsU+w9Mcq+uIVYzjVrBoe5u8ZLE0hPSkluH8URhcxtSQJ+gXcB0L
JHsseAeXVcgqoxTSJ6/n0xTCeXEnGwSRAzrqTvjS2gbd3TILxsfIHwRgwwPjBDgm
tjzbHHOFTJB3GCtH65T9A0viM2B/IW9Wz73jkz02AVMrZBHQ67IJ2W9CoIjd5mdG
eIV36U9NXl+wZa/D90pLRsFVbItKgLXgF71CQ92vS/biTx8fA6UUCU2ToNczP5Ur
A/mDXCBCLakwa1I3ylRkgFwluJw9DqiYh56MRgsEABa+ZPrm1Qb9njQZK4Y4V+ML
IvGM3xVoHIlvaSN29ubTueLpTeuAwN2VTiRzfOyCRKTcMBCtlMw1WCJNAMiNWDWS
BMnY9SlKv1oujmjS/ti0ptcipMymIoeWpVuQt3Mj8lYlKRpd6Zg8MbljMwQRSClK
6O6MSwpM3Xy5uJGh2cY5oYmKtxfyHSuKtKsk+daAPV1lpWYp9bNrbsLUPwmSY+zk
VgkZdiWBF//RP/72/esANONINy5hkWjkVd0NLjA5TAgk+DVVmnPtQIj1vBgtk8ak
Y9CczIbEgKBonkHWn+GX2ycR6jadg2P+xrBFg4MGjomkb2gtAgMBAAGjggGXMIIB
kzAfBgNVHSMEGDAWgBSdhWEUfMFib5do5E83QOGt4A1WNzAdBgNVHQ4EFgQU8ijU
+dQcfhprFoLl75Mpae3KFSAwDgYDVR0PAQH/BAQDAgEGMBMGA1UdJQQMMAoGCCsG
AQUFBwMBMEoGA1UdIARDMEEwNQYLKwYBBAGCvyUBARUwJjAkBggrBgEFBQcCARYY
aHR0cHM6Ly93d3cudHdjYS5jb20udHcvMAgGBmeBDAECAjBNBgNVHR8ERjBEMEKg
QKA+hjxodHRwOi8vUm9vdENBLnR3Y2EuY29tLnR3L1RXQ0FSQ0EvY3liZXJfcm9v
dF9yZXZva2VfMjAyMi5jcmwwEgYDVR0TAQH/BAgwBgEB/wIBADB9BggrBgEFBQcB
AQRxMG8wQwYIKwYBBQUHMAKGN2h0dHA6Ly9zc2xzZXJ2ZXIudHdjYS5jb20udHcv
Y2FjZXJ0L2N5YmVyX3Jvb3RfMjAyMi5jcnQwKAYIKwYBBQUHMAGGHGh0dHA6Ly9y
b290b2NzcC50d2NhLmNvbS50dy8wDQYJKoZIhvcNAQEMBQADggIBAIFF/6Gnvu8L
3xQDIampB8QVgoKS2bcjte0uJBbCrQHpzcGTuVTkZaiA86LwVz6SAU7TVgVYRXmt
x8l29WzfKI6wOAzmvlGZxSYAdN0I6YBkJK1nmDs0+TSw5lCzb+UOpajNOaMdJ5SN
YTN87yRwl82AFrwUmSLaMV4tN7W49N0SsELWs/d4uNHSMM0mBjd0hLDIWJFwOkuD
yOWahnCVfPlCwSVWpUntOGgOHOA02IUE+JNX+spIV1SwAMYaEVyHe316YUgiGA5y
k3liTa3vuv06eE1J2yiWrs9booW2VTHD+amzucFFNN1KvSLjSbYxG1t/FclHEN/y
6hGM3bkjRC31A0jzpv93D3MUQTdJascicPa0H4i8hviRriyetaC6HC4q8FQUTo2A
cEpxicNGgyHhDV+YdbnS6GZL+f3bsmMM8ZFYZ77mDTS9mRO1VnIwkjiN4vpzh67a
KTpoD9TQzZcGQiJy6Pi+PCSFiqjK7UD/63L/Pt0hpoNKvZLrz4ngrlpyzpx8KjeS
A5cjKcc6vlHm0Kk07k5djhJsaqQELso5r+UXi9qC+nwqPuR/w5kJZv4fz0ND4UhY
5y3qd+iCikkF3WzOzey7jUH9URKb3iZnRAHZvmyLK57UI0FwP+5xZEByvwXDtxbe
914Hj3cSUrmKT3g/ZlOQQ1THeu48MA79
-----END CERTIFICATE-----"""
with tempfile.TemporaryDirectory(prefix="niu-school-trust-") as directory:
    folder = Path(directory)
    (folder / "root.der").write_bytes(der)
    subprocess.run(["openssl", "x509", "-inform", "DER", "-in", str(folder / "root.der"),
                    "-out", str(folder / "root.pem")], check=True)
    (folder / "intermediate.pem").write_text(INTERMEDIATE + "\n")
    # -trusted uses only this root, never the machine's own store.
    verified = subprocess.run(["openssl", "verify", "-attime", "1800000000",
                               "-trusted", str(folder / "root.pem"), str(folder / "intermediate.pem")],
                              capture_output=True, text=True)
    assert verified.returncode == 0, verified.stdout + verified.stderr

# Only school hosts, and only after the system's own evaluation fails.
assert 'host == "niu.edu.tw" || host.hasSuffix(".niu.edu.tw")' in trust
handle = trust[trust.index("static func handle("):trust.index("static func respond(")]
assert handle.index("!SecTrustEvaluateWithError(trust, nil)") < handle.index("addCyberRoot(to: trust)")
respond = trust[trust.index("static func respond("):trust.index("static func isSchoolHost(")]
assert respond.index("if await evaluate(trust) { return (.performDefaultHandling, nil) }") < respond.index("addCyberRoot(to: trust)")
assert "SecTrustSetAnchorCertificatesOnly(trust, false)" in trust, "System roots must stay trusted"

# Every ccsys1 request and WebView uses it.
delegate = "delegate: SchoolServerTrust.delegate"
for path in ["Core/Services/SSOGUIDBridge.swift", "Core/Services/SSOTokenRenewer.swift",
             "Core/Services/ConnectionStatusService.swift",
             "Features/Authentication/Services/SSOLoginWebView.swift"]:
    assert delegate in (root / path).read_text(), f"{path} must pass {delegate}"
login = (root / "Features/Authentication/Services/SSOLoginWebView.swift").read_text()
info = login[login.index("private func fetchAuthorizationInfo"):login.index("private func bootstrapLegacyPortalSession")]
assert delegate in info, "Authorization/info must use the school trust"
for path in ["Features/Authentication/Services/SSOLoginWebView.swift",
             "Features/GradeHistory/Views/GradeHistoryView.swift",
             "Features/ClassSchedule/Services/ClassScheduleWebView.swift",
             "Features/LeaveApplication/LeaveApplicationService.swift",
             # Std002.aspx and expired ccsys sessions redirect to ccsys1.
             "Features/Moodle/Services/MoodleSessionManager.swift",
             "Features/Moodle/Views/MoodleWebView.swift",
             "Features/GraduationThreshold/Services/GraduationThresholdWebManager.swift",
             "Features/EnrollmentCertificate/Services/EnrollmentCertificateService.swift",
             "Features/EventRegistration/Services/EventRegistrationClient.swift"]:
    source = (root / path).read_text()
    assert "respondTo challenge: URLAuthenticationChallenge" in source, f"{path} must answer server trust"
    assert "await SchoolServerTrust.respond(to: challenge)" in source, path

# ATS rejects a failed system trust before the delegate can add the root, so ccsys1
# needs an exception; keep it to that one host.
plist = plistlib.loads((root / "App/Info.plist").read_bytes())
ats = plist["NSAppTransportSecurity"]
assert set(ats) == {"NSExceptionDomains"}, "No global ATS relaxation"
assert ats["NSExceptionDomains"] == {"ccsys1.niu.edu.tw": {
    "NSExceptionAllowsInsecureHTTPLoads": True, "NSIncludesSubdomains": False}}, \
    "ATS exception must only cover ccsys1"

project = (root / "NIU-App.xcodeproj/project.pbxproj").read_text()
assert project.count("SchoolServerTrust.swift in Sources") == 2, "Add SchoolServerTrust.swift to the app target"
print("School trust checks passed")
