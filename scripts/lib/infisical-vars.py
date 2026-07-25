#!/usr/bin/env python3
"""Fetch the Ansible-bound secrets from Infisical into an extra-vars YAML file.

THE single implementation, shared by scripts/deploy.sh (laptop) and
.github/workflows/deploy-platform.yaml (CI). Both used to carry a hand-synced
copy of the same login + fetch + escaping + missing-key check, with a comment
on each saying "if you change one, change the other" — which is exactly the
kind of thing that drifts.

Usage:
    infisical-vars.py <site|platform> <output-path>

    site      — everything site.yml needs, including the Tailscale OAuth
                credentials the tailscale role logs in with.
    platform  — everything platform.yml needs. No Tailscale OAuth: the
                platform play only reads Tailscale *facts* off an
                already-joined node (roles/tailscale/tasks/facts.yml).

Environment:
    INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET — universal-auth machine
    identity. These are ALSO written into the output file: the Infisical
    operator running in-cluster needs them, and they can't come from
    Infisical itself (chicken-and-egg).

Each secret path is fetched EXPLICITLY (not recursively) so short keys can
repeat across services without colliding. Any missing key is a hard failure:
silently dropping one lets an Ansible role default paper over a real Infisical
misconfiguration.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://eu.infisical.com"
WORKSPACE = "jterrazz"
ENVIRONMENT = "prod"

ROOT_PATH = "/jterrazz-infrastructure"
GRAFANA_PATH = "/jterrazz-infrastructure/grafana"

# ansible variable -> (infisical secret path, key at that path)
COMMON_VARS = {
    "cloudflare_api_token": (ROOT_PATH, "CLOUDFLARE_API_TOKEN"),
    "cloudflare_tunnel_token": (ROOT_PATH, "CLOUDFLARE_TUNNEL_TOKEN"),
    "registry_password": (ROOT_PATH, "DOCKER_REGISTRY_PASSWORD"),
    "grafana_admin_password": (GRAFANA_PATH, "ADMIN_PASSWORD"),
}

SITE_ONLY_VARS = {
    "tailscale_oauth_client_id": (ROOT_PATH, "TAILSCALE_OAUTH_CLIENT_ID"),
    "tailscale_oauth_client_secret": (ROOT_PATH, "TAILSCALE_OAUTH_CLIENT_SECRET"),
}

SCOPES = {
    "site": {**COMMON_VARS, **SITE_ONLY_VARS},
    "platform": COMMON_VARS,
}


def die(message):
    # GitHub renders `::error::` as an annotation on the failing step; a plain
    # line is fine everywhere else.
    prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else "ERROR: "
    print(f"{prefix}{message}", file=sys.stderr)
    sys.exit(1)


def post_json(url, payload):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def login(client_id, client_secret):
    try:
        return post_json(
            f"{API}/api/v1/auth/universal-auth/login",
            {"clientId": client_id, "clientSecret": client_secret},
        )["accessToken"]
    except (urllib.error.URLError, KeyError, ValueError) as exc:
        die(f"Infisical universal-auth login failed: {exc}")


def fetch_path(token, secret_path):
    query = urllib.parse.urlencode(
        {
            "workspaceSlug": WORKSPACE,
            "environment": ENVIRONMENT,
            "secretPath": secret_path,
        }
    )
    request = urllib.request.Request(
        f"{API}/api/v3/secrets/raw?{query}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except (urllib.error.URLError, ValueError) as exc:
        die(f"Infisical fetch of {secret_path} failed: {exc}")
    return {s["secretKey"]: s["secretValue"] for s in body.get("secrets", [])}


def yaml_escape(value):
    # Quote everything: tokens may start with `[` or contain `:`, both of which
    # mean things to the YAML parser. Escape embedded newlines too, so a
    # multi-line secret can't break the file.
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in SCOPES:
        die(f"usage: {sys.argv[0]} <{'|'.join(SCOPES)}> <output-path>")

    scope, outpath = sys.argv[1], sys.argv[2]
    wanted = SCOPES[scope]

    client_id = os.environ.get("INFISICAL_CLIENT_ID")
    client_secret = os.environ.get("INFISICAL_CLIENT_SECRET")
    if not client_id or not client_secret:
        die("INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET must be set")

    token = login(client_id, client_secret)

    cache = {}
    for path, _ in set(wanted.values()):
        if path not in cache:
            cache[path] = fetch_path(token, path)

    out = {var: cache[path].get(key) for var, (path, key) in wanted.items()}

    missing = sorted(var for var, value in out.items() if value is None)
    if missing:
        die(f"Missing Infisical secrets: {', '.join(missing)}")

    out["infisical_client_id"] = client_id
    out["infisical_client_secret"] = client_secret

    # 0600 from the moment the file exists — it never has a world-readable
    # window, even if the caller forgot to mktemp it.
    fd = os.open(outpath, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        for var, value in out.items():
            handle.write(f'{var}: "{yaml_escape(value)}"\n')


if __name__ == "__main__":
    main()
