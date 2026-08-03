#!/usr/bin/env python3
"""Small App Store Connect helper for TestFlight upload workflows."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


API = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_KEY_ID = "7D3YAT286X"
DEFAULT_ISSUER_ID = "bb0c9a32-bd23-405d-9e9b-4eb0703dc5ea"
DEFAULT_KEY_PATH = "/Users/yangzhiyuan/private_keys/AuthKey_7D3YAT286X.p8"


def env(name: str, alt: str, default: str | None = None) -> str:
    value = os.environ.get(name) or os.environ.get(alt) or default
    if not value:
        raise SystemExit(f"Missing {name} or {alt}")
    return value


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token() -> str:
    key_id = env("APP_STORE_CONNECT_KEY_ID", "ASC_KEY_ID", DEFAULT_KEY_ID)
    issuer_id = env("APP_STORE_CONNECT_ISSUER_ID", "ASC_ISSUER_ID", DEFAULT_ISSUER_ID)
    key_path = Path(env("APP_STORE_CONNECT_KEY_PATH", "ASC_KEY_PATH", DEFAULT_KEY_PATH)).expanduser()
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode()
    private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(signature)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input.decode() + "." + b64url(raw)


def request(path: str, method: str = "GET", body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": "Bearer " + make_token()}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw or "{}")
    except urllib.error.HTTPError as exc:
        sys.stderr.write(exc.read().decode(errors="replace") + "\n")
        raise


def query(path: str, **params: str) -> dict:
    return request(path + "?" + urllib.parse.urlencode(params))


def list_apps(_args: argparse.Namespace) -> None:
    data = query("/apps", limit="200")
    rows = []
    for app in data.get("data", []):
        attrs = app["attributes"]
        rows.append(
            {
                "id": app["id"],
                "name": attrs.get("name"),
                "bundleId": attrs.get("bundleId"),
                "sku": attrs.get("sku"),
                "primaryLocale": attrs.get("primaryLocale"),
            }
        )
    print(json.dumps(rows, ensure_ascii=False, indent=2))


def find_bundle(bundle_identifier: str) -> dict:
    """Return the exact bundle ID match, not a prefix-matched extension ID."""
    data = query("/bundleIds", limit="200")
    for bundle in data.get("data", []):
        if bundle["attributes"].get("identifier") == bundle_identifier:
            return bundle
    raise SystemExit(f"No exact bundle ID found for {bundle_identifier}")


def cert_sha1(cert: dict) -> str:
    content = cert["attributes"].get("certificateContent")
    if not content:
        return ""
    return hashlib.sha1(base64.b64decode(content)).hexdigest().upper()


def find_cert(cert_sha: str) -> dict:
    wanted = cert_sha.replace(":", "").upper()
    matches = []
    for cert_type in ("DISTRIBUTION", "IOS_DISTRIBUTION"):
        data = query("/certificates", **{"filter[certificateType]": cert_type, "limit": "200"})
        for cert in data.get("data", []):
            sha = cert_sha1(cert)
            if sha == wanted:
                return cert
            matches.append(
                {
                    "id": cert["id"],
                    "type": cert["attributes"].get("certificateType"),
                    "displayName": cert["attributes"].get("displayName"),
                    "expirationDate": cert["attributes"].get("expirationDate"),
                    "sha1": sha,
                }
            )
    raise SystemExit("No matching distribution certificate. Available:\n" + json.dumps(matches, indent=2))


def ensure_profile(args: argparse.Namespace) -> None:
    bundle = find_bundle(args.bundle_id)
    cert = find_cert(args.cert_sha1)
    existing = query("/profiles", **{"filter[profileType]": "IOS_APP_STORE", "include": "bundleId,certificates", "limit": "200"})
    included = {item["id"]: item for item in existing.get("included", []) if item.get("type") == "bundleIds"}
    for profile in existing.get("data", []):
        attrs = profile["attributes"]
        relationship = profile.get("relationships", {}).get("bundleId", {}).get("data", {})
        profile_bundle = included.get(relationship.get("id"), {}).get("attributes", {}).get("identifier")
        if attrs.get("name") == args.profile_name and profile_bundle == args.bundle_id:
            install_profile(attrs)
            print(json.dumps({"action": "installed-existing", "id": profile["id"], "name": attrs.get("name"), "uuid": attrs.get("uuid")}, indent=2))
            return
    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": args.profile_name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
            },
        }
    }
    created = request("/profiles", "POST", body)["data"]
    attrs = created["attributes"]
    install_profile(attrs)
    print(json.dumps({"action": "created-installed", "id": created["id"], "name": attrs.get("name"), "uuid": attrs.get("uuid")}, indent=2))


def install_profile(attrs: dict) -> Path:
    content = attrs.get("profileContent")
    if not content:
        raise SystemExit("Profile response has no profileContent")
    uuid = attrs["uuid"]
    target = Path.home() / "Library/MobileDevice/Provisioning Profiles" / f"{uuid}.mobileprovision"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(base64.b64decode(content))
    return target


def find_group(app_id: str, name: str, create: bool) -> dict:
    data = query("/betaGroups", **{"filter[app]": app_id, "limit": "200"})
    for group in data.get("data", []):
        if group["attributes"].get("name") == name:
            return group
    if not create:
        raise SystemExit(f"No beta group named {name!r}")
    body = {
        "data": {
            "type": "betaGroups",
            "attributes": {"name": name, "isInternalGroup": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }
    return request("/betaGroups", "POST", body)["data"]


def poll_and_add(args: argparse.Namespace) -> None:
    deadline = time.time() + args.timeout
    last = []
    while time.time() < deadline:
        data = query(
            "/builds",
            **{"filter[app]": args.app_id, "filter[version]": str(args.build_number), "sort": "-uploadedDate", "limit": "5"},
        )
        builds = data.get("data", [])
        last = [
            {
                "id": b["id"],
                "version": b["attributes"].get("version"),
                "processingState": b["attributes"].get("processingState"),
                "usesNonExemptEncryption": b["attributes"].get("usesNonExemptEncryption"),
            }
            for b in builds
        ]
        print("poll", json.dumps(last, ensure_ascii=False), flush=True)
        if builds and builds[0]["attributes"].get("processingState") == "VALID":
            build = builds[0]
            detail = request(f"/builds/{build['id']}/buildBetaDetail")["data"]["attributes"]
            print("detail", json.dumps(detail, ensure_ascii=False), flush=True)
            if detail.get("internalBuildState") not in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
                raise SystemExit(f"Build is not internally testable: {detail.get('internalBuildState')}")
            group = find_group(args.app_id, args.group_name, args.create_group)
            body = {"data": [{"type": "builds", "id": build["id"]}]}
            try:
                request(f"/betaGroups/{group['id']}/relationships/builds", "POST", body)
            except urllib.error.HTTPError as exc:
                if exc.code not in (409, 422):
                    raise
            print(json.dumps({"addedBuild": build["id"], "buildNumber": args.build_number, "groupId": group["id"], "groupName": args.group_name}, indent=2))
            return
        time.sleep(args.interval)
    raise SystemExit("Timed out waiting for build. Last poll: " + json.dumps(last, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="App Store Connect helper for TestFlight workflows")
    sub = parser.add_subparsers(required=True)
    p = sub.add_parser("list-apps")
    p.set_defaults(func=list_apps)
    p = sub.add_parser("ensure-profile")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--profile-name", required=True)
    p.add_argument("--cert-sha1", required=True)
    p.set_defaults(func=ensure_profile)
    p = sub.add_parser("poll-and-add")
    p.add_argument("--app-id", required=True)
    p.add_argument("--build-number", required=True)
    p.add_argument("--group-name", default="Internal Testers")
    p.add_argument("--create-group", action="store_true")
    p.add_argument("--timeout", type=int, default=420)
    p.add_argument("--interval", type=int, default=30)
    p.set_defaults(func=poll_and_add)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
