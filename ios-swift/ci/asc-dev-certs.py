#!/usr/bin/env python3
"""CI 归档后吊销这次新建的开发证书（ADR 0023）。

每次在新机器上归档，自动签名都要一张「Apple Development」证书来签归档；新机器上没有私钥，
Xcode 就用 API 密钥新建一张。证书有数量上限，攒满了归档就失败
（「Your account has reached the maximum number of certificates」）。

归档前用 App Store Connect API 记下开发者账号里现有的开发证书，上传结束后（成功、失败都算）
再查一次，吊销多出来的那张，数量就不会涨。上传一次只跑一个（工作流的 concurrency），这期间多出来的就是这次建的。
不看钥匙串：第一版按钥匙串找新证书，第 12 次运行没找到，证书留下了。
只动开发证书，分发证书和归档前就有的（包括自己建的）不碰。归档前没查到列表就不吊销，免得把原有的当成新的。
结果写成 GitHub 的 notice / warning，在运行页面的 Annotations 里看得到。

用法：
  asc-dev-certs.py snapshot <文件> <p8 路径>     记下现有开发证书
  asc-dev-certs.py revoke-new <文件> <p8 路径>   吊销快照之后多出来的开发证书
需要环境变量 ASC_KEY_ID、ASC_ISSUER_ID。只用 Python 标准库和系统自带的 openssl。都不会让上传失败。
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}
SNAPSHOT_OK = "ok"


def notice(message):
    print("::notice title=开发证书::" + message)


def warning(message):
    print("::warning title=开发证书::" + message)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl 给的 ECDSA 签名是 DER（SEQUENCE { INTEGER r, INTEGER s }），JWT 的 ES256 要 r、s 各 32 字节拼起来"""
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        length = der[i + 1]
        value = der[i + 2:i + 2 + length].lstrip(b"\x00")
        i += 2 + length
        parts.append(value.rjust(32, b"\x00"))
    return b"".join(parts)


def token(key_path):
    """App Store Connect API 的 JWT（ES256，10 分钟）"""
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    compact = lambda obj: json.dumps(obj, separators=(",", ":")).encode()
    signing_input = b64url(compact(header)) + "." + b64url(compact(payload))
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(), capture_output=True, check=True,
    ).stdout
    return signing_input + "." + b64url(der_to_raw(der))


def call(method, url, jwt):
    request = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + jwt})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


def development_certificates(jwt):
    """开发者账号里的开发证书：{id: 属性}"""
    url = API + "/certificates?limit=200&fields%5Bcertificates%5D=name,certificateType,serialNumber,expirationDate"
    found = {}
    while url:
        page = call("GET", url, jwt)
        for certificate in page.get("data", []):
            attributes = certificate.get("attributes", {})
            if attributes.get("certificateType") in DEVELOPMENT_TYPES:
                found[certificate["id"]] = attributes
        url = page.get("links", {}).get("next")
    return found


def snapshot(path, key_path):
    try:
        ids = sorted(development_certificates(token(key_path)))
    except Exception as error:
        with open(path, "w") as f:
            f.write("")
        warning("归档前没查到开发证书列表（%s），这次结束时不吊销" % describe(error))
        return
    with open(path, "w") as f:
        f.write("\n".join([SNAPSHOT_OK] + ids))
    notice("归档前有 %d 张开发证书" % len(ids))


def revoke_new(path, key_path):
    try:
        with open(path) as f:
            lines = f.read().split()
    except OSError:
        lines = []
    if not lines or lines[0] != SNAPSHOT_OK:
        warning("归档前没记下开发证书，不吊销；以后满了到 Certificates 里手动吊销「Created via API」")
        return
    before = set(lines[1:])
    jwt = token(key_path)
    now = development_certificates(jwt)
    new = {cid: attributes for cid, attributes in now.items() if cid not in before}
    if not new:
        notice("这次没有新建开发证书（现在 %d 张）" % len(now))
        return
    for cid, attributes in new.items():
        call("DELETE", API + "/certificates/" + cid, jwt)
        notice("已吊销这次新建的开发证书：%s，到期 %s" % (attributes.get("name"), (attributes.get("expirationDate") or "")[:10]))


def describe(error):
    if isinstance(error, urllib.error.HTTPError):
        return "HTTP %d %s" % (error.code, error.read().decode(errors="replace")[:200])
    return str(error)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("snapshot", "revoke-new"):
        sys.exit(__doc__)
    if sys.argv[1] == "snapshot":
        snapshot(sys.argv[2], sys.argv[3])
        return
    try:
        revoke_new(sys.argv[2], sys.argv[3])
    except Exception as error:  # 清理失败不影响上传结果
        warning("吊销这次新建的开发证书失败（%s）" % describe(error))


if __name__ == "__main__":
    main()
