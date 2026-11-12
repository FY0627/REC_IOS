#!/usr/bin/env python3
"""CI 归档后吊销这次新建的开发证书（ADR 0023）。

每次在新机器上归档，自动签名都要一张「Apple Development」证书来签归档；新机器的钥匙串里没有私钥，
Xcode 就用 API 密钥新建一张。证书有数量上限，攒满了归档就失败
（「Your account has reached the maximum number of certificates」）。
归档前记下钥匙串里已有的开发证书，上传结束后（成功、失败都算）用 App Store Connect API 吊销这次新出现的，数量就不会涨。
只吊销开发证书，分发证书（云端管理）不碰。

用法：
  asc-dev-certs.py snapshot <文件>              记下钥匙串里现有开发证书的序列号
  asc-dev-certs.py revoke-new <文件> <p8 路径>   吊销快照之后新出现的开发证书
需要环境变量 ASC_KEY_ID、ASC_ISSUER_ID。只用 Python 标准库和系统自带的 openssl、security。
吊销失败只打警告，不让上传失败。
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
DEVELOPMENT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}


def normalize(serial):
    """序列号统一成大写十六进制、去掉前导零：钥匙串和 API 的写法不一定一样"""
    return serial.strip().upper().lstrip("0") or "0"


def keychain_serials():
    """钥匙串里「Apple Development」证书的序列号"""
    try:
        pem = subprocess.run(
            ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
            capture_output=True, text=True,
        ).stdout
    except FileNotFoundError:
        return set()
    serials = set()
    for block in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pem, re.S):
        out = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=block, capture_output=True, text=True).stdout
        match = re.search(r"serial=([0-9A-Fa-f]+)", out)
        if match:
            serials.add(normalize(match.group(1)))
    return serials


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


def snapshot(path):
    serials = sorted(keychain_serials())
    with open(path, "w") as f:
        f.write("\n".join(serials))
    print("开发证书（归档前）：%d 张" % len(serials))


def revoke_new(path, key_path):
    with open(path) as f:
        before = set(f.read().split())
    new = keychain_serials() - before
    if not new:
        print("这次没有新建开发证书")
        return
    jwt = token(key_path)
    url = API + "/certificates?limit=200&fields%5Bcertificates%5D=serialNumber,certificateType,name"
    certificates = []
    while url:
        page = call("GET", url, jwt)
        certificates += page.get("data", [])
        url = page.get("links", {}).get("next")
    found = set()
    for certificate in certificates:
        attributes = certificate.get("attributes", {})
        serial = normalize(attributes.get("serialNumber") or "")
        if serial not in new or attributes.get("certificateType") not in DEVELOPMENT_TYPES:
            continue
        call("DELETE", API + "/certificates/" + certificate["id"], jwt)
        found.add(serial)
        print("已吊销这次新建的开发证书：%s（%s）" % (attributes.get("name"), serial))
    for serial in new - found:
        print("::warning title=开发证书::钥匙串里新出现的开发证书 %s 在开发者账号里没找到，没有吊销" % serial)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "snapshot":
        snapshot(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "revoke-new":
        try:
            revoke_new(sys.argv[2], sys.argv[3])
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:300]
            print("::warning title=开发证书::吊销这次新建的开发证书失败（HTTP %d）：%s" % (error.code, detail))
        except Exception as error:  # 清理失败不影响上传结果
            print("::warning title=开发证书::吊销这次新建的开发证书失败：%s" % error)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
