#!/usr/bin/env python3
"""Assert the cross-file invariants this repo cannot express in one place.

Several facts in this repo are necessarily written down twice, in two
different languages, because two different machines consume them (Cloudflare
via Pulumi/TypeScript and CoreDNS via Ansible/YAML; a Traefik entrypoint
argument and a Traefik Middleware CRD; a Python secret map and an Ansible
assert block). Each pair carries a "KEEP IN SYNC" comment, and a comment is
not a check. This script is the check.

Run it:
    python3 scripts/assert-sync.py

Exit status is 0 only if every check passes; a failing check prints exactly
what to edit. It runs in `make lint` and in the `scripts` job of
.github/workflows/validate.yaml.

DESIGN NOTES
------------
* Stdlib only, on purpose. It has to run on a bare `ubuntu-latest` runner in
  the `scripts` job, which installs nothing (that job is deliberately the fast
  one) — so no PyYAML, no ruamel. The YAML this reads is a handful of flat
  block lists/maps, which a ~40-line parser handles exactly; anything more
  exotic than that in those files should fail loudly here rather than be
  silently half-parsed. Hence `_block_list` / `_block_map` raise on a missing
  key rather than returning empty.
* The TypeScript is read with a regex over the array literal. That is fragile
  BY DESIGN: if `PRIVATE_HOSTS` is renamed, moved into a function, or turned
  into a computed value, this script fails with "array literal not found"
  rather than quietly passing on zero entries. A rename is meant to force
  someone to look at this file — that is the whole point of a sync assertion.
* infisical-vars.py is read with `ast`, not regex: it is Python, so the real
  parser is free and exact.
"""

import ast
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GROUP_VARS = "ansible/inventories/group_vars/all.yml"
DNS_TS = "pulumi/src/dns.ts"
INFISICAL_VARS = "scripts/lib/infisical-vars.py"
PREFLIGHT = "ansible/roles/platform/tasks/preflight.yml"
TRAEFIK_CONFIG = "kubernetes/cluster/traefik/traefik-config.yaml"
MIDDLEWARE = "kubernetes/cluster/traefik/middleware.yaml"
PLATFORM_TASKS = "ansible/roles/platform/tasks"


# ---------------------------------------------------------------------------
# Tiny readers
# ---------------------------------------------------------------------------

class SyncError(Exception):
    """A check could not even be evaluated (a file or key moved/renamed)."""


def read(relpath):
    path = os.path.join(REPO, relpath)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise SyncError(f"cannot read {relpath}: {exc}") from exc


def _strip_comment(value):
    """Drop a trailing `# ...` comment from a YAML scalar line.

    Only a `#` preceded by whitespace starts a comment in YAML, so
    `10.42.0.0/16 # k3s pod CIDR` loses the comment while a `#` inside a value
    would not. Quotes are stripped afterwards by the caller.
    """
    match = re.search(r"\s+#", value)
    if match:
        value = value[: match.start()]
    return value.strip()


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _block_body(text, key, source):
    """Return the indented lines that follow a top-level `key:` line."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}\s*:\s*$", line):
            start = index + 1
            break
    if start is None:
        raise SyncError(
            f"{source}: no top-level `{key}:` block. If it was renamed or "
            f"restructured, update scripts/assert-sync.py alongside it."
        )
    body = []
    for line in lines[start:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[:1].isspace():
            break
        body.append(line)
    return body


def block_list(text, key, source):
    """Parse a flat YAML block sequence: `key:` then `  - value` lines."""
    out = []
    for line in _block_body(text, key, source):
        stripped = line.strip()
        if not stripped.startswith("- "):
            raise SyncError(
                f"{source}: `{key}:` is not a flat list of `- value` entries "
                f"(offending line: {stripped!r}). assert-sync.py's parser is "
                f"deliberately narrow — extend it or simplify the file."
            )
        out.append(_unquote(_strip_comment(stripped[2:])))
    return out


def block_map(text, key, source):
    """Parse a flat YAML block mapping: `key:` then `  name: value` lines."""
    out = {}
    for line in _block_body(text, key, source):
        stripped = line.strip()
        if ":" not in stripped:
            raise SyncError(
                f"{source}: `{key}:` is not a flat `name: value` mapping "
                f"(offending line: {stripped!r})."
            )
        name, _, value = stripped.partition(":")
        out[name.strip()] = _unquote(_strip_comment(value))
    return out


def ts_string_array(text, name, source):
    """Read a `const NAME = ["a", "b"];` array literal out of TypeScript."""
    match = re.search(
        rf"^const\s+{re.escape(name)}\s*(?::[^=]+)?=\s*\[(?P<body>[^\]]*)\]\s*;",
        text,
        re.MULTILINE,
    )
    if not match:
        raise SyncError(
            f"{source}: no `const {name} = [...]` array literal. It was "
            f"renamed, moved, or made computed — update the matching check in "
            f"scripts/assert-sync.py so the two files stay verifiably in sync."
        )
    return re.findall(r"""["'`]([^"'`]+)["'`]""", match.group("body"))


# ---------------------------------------------------------------------------
# Checks. Each returns a list of human-readable problems (empty == pass).
# ---------------------------------------------------------------------------

def check_private_hosts():
    """(a) Cloudflare CNAMEs (Pulumi) vs the CoreDNS override list (Ansible).

    pulumi/src/dns.ts creates the PUBLIC CNAME `<host>.jterrazz.com` ->
    tailnet FQDN. group_vars' `private_hostnames` (+ the `_via_traefik`
    variant, which differs only in what CoreDNS points them AT) drives the
    in-cluster split-DNS override. A host in one list and not the other is
    either a name that resolves publicly but not in-cluster, or an in-cluster
    override for a name that does not resolve at all.
    """
    problems = []
    gv = read(GROUP_VARS)
    ts = read(DNS_TS)

    direct = block_list(gv, "private_hostnames", GROUP_VARS)
    via_traefik = block_list(gv, "private_hostnames_via_traefik", GROUP_VARS)
    ansible_fqdns = direct + via_traefik

    suffix = ".jterrazz.com"
    bad = [h for h in ansible_fqdns if not h.endswith(suffix)]
    if bad:
        problems.append(
            f"{GROUP_VARS}: private hostname(s) not under {suffix}: "
            f"{', '.join(sorted(bad))}. dns.ts can only create records in the "
            f"jterrazz.com zone, so this check cannot compare them."
        )
    ansible_hosts = {h[: -len(suffix)] for h in ansible_fqdns if h.endswith(suffix)}

    pulumi_private = set(ts_string_array(ts, "PRIVATE_HOSTS", DNS_TS))
    pulumi_public = set(ts_string_array(ts, "PUBLIC_TUNNEL_HOSTS", DNS_TS))

    only_pulumi = sorted(pulumi_private - ansible_hosts)
    only_ansible = sorted(ansible_hosts - pulumi_private)

    if only_pulumi:
        problems.append(
            f"in PRIVATE_HOSTS ({DNS_TS}) but NOT in {GROUP_VARS}: "
            f"{', '.join(only_pulumi)}.\n"
            f"        FIX: either add {', '.join(h + suffix for h in only_pulumi)} "
            f"to `private_hostnames` (in-cluster lookups must be short-circuited "
            f"to the node's tailnet IP; CoreDNS cannot chase the public CNAME "
            f"into the tailnet zone) or `private_hostnames_via_traefik` (if the "
            f"host must resolve to Traefik's ClusterIP in-cluster) — or delete "
            f"the entry from PRIVATE_HOSTS if the service is gone (a CNAME "
            f"pointing at a host that 404s reads as an outage, not an absence)."
        )
    if only_ansible:
        problems.append(
            f"in {GROUP_VARS} but NOT in PRIVATE_HOSTS ({DNS_TS}): "
            f"{', '.join(only_ansible)}.\n"
            f"        FIX: add {', '.join(repr(h) for h in only_ansible)} to "
            f"PRIVATE_HOSTS in {DNS_TS} (nothing creates the public CNAME for "
            f"it today, so the name does not resolve off-cluster), or remove it "
            f"from the group_vars list."
        )

    overlap = sorted(pulumi_private & pulumi_public)
    if overlap:
        problems.append(
            f"{DNS_TS}: {', '.join(overlap)} appear(s) in BOTH PRIVATE_HOSTS "
            f"and PUBLIC_TUNNEL_HOSTS. Pulumi would declare two CNAMEs for one "
            f"name (one proxied at the edge, one straight to the tailnet); the "
            f"second apply wins nondeterministically. Pick one."
        )
    return problems


def check_secret_keys():
    """(b) The Infisical var map (Python) vs the Ansible preflight assert.

    infisical-vars.py writes exactly one extra-vars file; preflight.yml is the
    gate that refuses to deploy without those vars. A var fetched but not
    asserted has no gate; a var asserted but not fetched fails every deploy.

    Scoped to the PLATFORM scope, because preflight.yml lives in
    roles/platform and both playbooks reach it through that role: site.yml
    imports platform.yml, and .github/workflows/deploy-platform.yaml runs
    platform.yml alone. The site-only extras (the Tailscale OAuth pair) are
    consumed by roles/tailscale, never by the platform role, so asserting them
    here would break every CI platform deploy — which is exactly why the scope
    is read out of SCOPES rather than hardcoded.
    """
    problems = []
    src = read(INFISICAL_VARS)
    tree = ast.parse(src, INFISICAL_VARS)

    maps = {}
    scopes_node = None
    written_directly = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            # <NAME>_VARS = { "<ansible var>": (secret path, key at that path) }
            if isinstance(target, ast.Name) and target.id.endswith("_VARS"):
                if not isinstance(node.value, ast.Dict):
                    raise SyncError(
                        f"{INFISICAL_VARS}: {target.id} is no longer a dict "
                        f"literal — update scripts/assert-sync.py."
                    )
                keys = set()
                for key in node.value.keys:
                    if not isinstance(key, ast.Constant):
                        raise SyncError(
                            f"{INFISICAL_VARS}: {target.id} has a computed key; "
                            f"assert-sync.py can only read literals."
                        )
                    keys.add(key.value)
                maps[target.id] = keys
            if isinstance(target, ast.Name) and target.id == "SCOPES":
                scopes_node = node.value
            # The credentials the script writes itself (chicken-and-egg: the
            # in-cluster operator needs them and they cannot come from
            # Infisical). Shape: out["infisical_client_id"] = client_id
            if (
                isinstance(target, ast.Subscript)
                and isinstance(target.value, ast.Name)
                and target.value.id == "out"
                and isinstance(target.slice, ast.Constant)
            ):
                written_directly.add(target.slice.value)

    if not maps or scopes_node is None:
        raise SyncError(
            f"{INFISICAL_VARS}: no `*_VARS` dict literal and/or no `SCOPES` "
            f"map found. The secret map was renamed or restructured — update "
            f"scripts/assert-sync.py."
        )
    if not isinstance(scopes_node, ast.Dict):
        raise SyncError(f"{INFISICAL_VARS}: SCOPES is not a dict literal.")

    platform_value = None
    for key, value in zip(scopes_node.keys, scopes_node.values):
        if isinstance(key, ast.Constant) and key.value == "platform":
            platform_value = value
    if platform_value is None:
        raise SyncError(
            f"{INFISICAL_VARS}: SCOPES has no \"platform\" entry, but "
            f"{PREFLIGHT} gates the platform play. Update both together."
        )

    def scope_keys(node):
        """Resolve a SCOPES value: `COMMON_VARS` or `{**A, **B}`."""
        if isinstance(node, ast.Name):
            if node.id not in maps:
                raise SyncError(
                    f"{INFISICAL_VARS}: SCOPES['platform'] references unknown "
                    f"map {node.id}."
                )
            return set(maps[node.id])
        if isinstance(node, ast.Dict):
            out = set()
            for key, value in zip(node.keys, node.values):
                if key is None:  # `**OTHER_MAP`
                    out |= scope_keys(value)
                elif isinstance(key, ast.Constant):
                    out.add(key.value)
                else:
                    raise SyncError(
                        f"{INFISICAL_VARS}: computed key in SCOPES['platform']."
                    )
            return out
        raise SyncError(
            f"{INFISICAL_VARS}: SCOPES['platform'] is an expression "
            f"assert-sync.py cannot resolve ({type(node).__name__})."
        )

    produced = scope_keys(platform_value) | written_directly

    # preflight.yml: the `that:` list of `- <var> is defined and <var> | ...`
    preflight = read(PREFLIGHT)
    match = re.search(r"^\s*that:\s*$", preflight, re.MULTILINE)
    if not match:
        raise SyncError(
            f"{PREFLIGHT}: no `that:` block found — the assert task was "
            f"restructured; update scripts/assert-sync.py."
        )
    asserted = set()
    for line in preflight[match.end():].splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("- "):
            break
        name = re.match(r"-\s*([A-Za-z_][A-Za-z0-9_]*)\b", stripped)
        if not name:
            raise SyncError(
                f"{PREFLIGHT}: unparseable assert entry {stripped!r}."
            )
        asserted.add(name.group(1))

    if not asserted:
        raise SyncError(f"{PREFLIGHT}: the `that:` list is empty.")

    unasserted = sorted(produced - asserted)
    unfetched = sorted(asserted - produced)
    if unasserted:
        problems.append(
            f"fetched by {INFISICAL_VARS} but NOT asserted in {PREFLIGHT}: "
            f"{', '.join(unasserted)}.\n"
            f"        FIX: add `- <var> is defined and <var> | length > 0` for "
            f"each to the assert's `that:` list (and name them in fail_msg). "
            f"An unasserted secret fails halfway through a deploy, or worse, "
            f"lets a role default paper over a real Infisical misconfiguration."
        )
    if unfetched:
        problems.append(
            f"asserted in {PREFLIGHT} but NOT produced by {INFISICAL_VARS}: "
            f"{', '.join(unfetched)}.\n"
            f"        FIX: add each to COMMON_VARS (both scopes need it) or "
            f"SITE_ONLY_VARS in {INFISICAL_VARS}, or drop the assert. As it "
            f"stands every platform deploy fails preflight."
        )
    return problems


def check_traefik_trusted_ips():
    """(c) Entrypoint forwardedHeaders.trustedIPs vs rate-limit excludedIPs.

    Both lists answer the same question — "which addresses are OUR hops" —
    for two different Traefik features. trustedIPs decides whether Traefik
    KEEPS the X-Forwarded-For header at all; excludedIPs decides which XFF
    element the rate limiter keys on. A range in one and not the other means
    the limiter either keys on one of our own proxies (one global bucket) or
    on an address Traefik already discarded.
    """
    problems = []

    # traefik-config.yaml embeds the whole Traefik chart config as a
    # `valuesContent: |-` STRING, so this is not addressable YAML. Match the
    # CLI argument itself, wherever it sits and however it is quoted.
    config = read(TRAEFIK_CONFIG)
    match = re.search(
        r"forwardedHeaders\.trustedIPs=([^\"'\s]+)",
        config,
    )
    if not match:
        raise SyncError(
            f"{TRAEFIK_CONFIG}: no "
            f"`--entryPoints.<name>.forwardedHeaders.trustedIPs=` argument. It "
            f"moved out of additionalArguments (or the entrypoint was renamed) "
            f"— update scripts/assert-sync.py."
        )
    trusted = {cidr.strip() for cidr in match.group(1).split(",") if cidr.strip()}

    # middleware.yaml holds several Middleware objects; only the rate-limit
    # one carries excludedIPs, but scope the search to its document anyway so
    # a future second excludedIPs cannot be picked up by accident.
    middleware = read(MIDDLEWARE)
    docs = [d for d in re.split(r"^---\s*$", middleware, flags=re.MULTILINE)]
    rate_limit_docs = [d for d in docs if re.search(r"^\s*name:\s*rate-limit\s*$", d, re.MULTILINE)]
    if len(rate_limit_docs) != 1:
        raise SyncError(
            f"{MIDDLEWARE}: expected exactly one `name: rate-limit` document, "
            f"found {len(rate_limit_docs)} — update scripts/assert-sync.py."
        )
    doc = rate_limit_docs[0]
    start = re.search(r"^(\s*)excludedIPs:\s*$", doc, re.MULTILINE)
    if not start:
        raise SyncError(
            f"{MIDDLEWARE}: the rate-limit middleware has no "
            f"`sourceCriterion.ipStrategy.excludedIPs:` list. If it switched to "
            f"`depth:`, that is a deliberate behaviour change — read the "
            f"comment in {MIDDLEWARE} and update scripts/assert-sync.py."
        )
    indent = len(start.group(1))
    excluded = set()
    for line in doc[start.end():].splitlines():
        if not line.strip():
            continue
        if len(line) - len(line.lstrip()) <= indent:
            break
        stripped = line.strip()
        if not stripped.startswith("- "):
            break
        excluded.add(_unquote(_strip_comment(stripped[2:])))

    only_trusted = sorted(trusted - excluded)
    only_excluded = sorted(excluded - trusted)
    if only_trusted:
        problems.append(
            f"in forwardedHeaders.trustedIPs ({TRAEFIK_CONFIG}) but NOT in the "
            f"rate-limit excludedIPs ({MIDDLEWARE}): {', '.join(only_trusted)}.\n"
            f"        FIX: add them to `excludedIPs`. Traefik trusts XFF from "
            f"these peers, so the limiter can end up keying on one of OUR hops "
            f"— every request through it shares a single bucket."
        )
    if only_excluded:
        problems.append(
            f"in the rate-limit excludedIPs ({MIDDLEWARE}) but NOT in "
            f"forwardedHeaders.trustedIPs ({TRAEFIK_CONFIG}): "
            f"{', '.join(only_excluded)}.\n"
            f"        FIX: add them to the "
            f"`--entryPoints.websecure.forwardedHeaders.trustedIPs=` argument. "
            f"Traefik STRIPS X-Forwarded-* from any peer not in that list, so "
            f"excluding the range here has no effect."
        )
    return problems


def check_chart_version_pins():
    """(d) Every `platform_chart_versions` pin is actually consumed.

    An orphan pin reads as "this chart is pinned" while the install it was
    written for is gone or unpinned — i.e. the next deploy silently adopts
    whatever the upstream repo's latest happens to be that day.
    """
    problems = []
    gv = read(GROUP_VARS)
    pins = block_map(gv, "platform_chart_versions", GROUP_VARS)
    if not pins:
        raise SyncError(f"{GROUP_VARS}: `platform_chart_versions` is empty.")

    tasks_dir = os.path.join(REPO, PLATFORM_TASKS)
    if not os.path.isdir(tasks_dir):
        raise SyncError(f"{PLATFORM_TASKS}: directory not found.")

    corpus = ""
    for name in sorted(os.listdir(tasks_dir)):
        if name.endswith((".yml", ".yaml")):
            corpus += read(os.path.join(PLATFORM_TASKS, name))

    orphans = [
        key
        for key in sorted(pins)
        if not re.search(rf"platform_chart_versions\.{re.escape(key)}\b", corpus)
        and not re.search(
            rf"platform_chart_versions\[\s*['\"]{re.escape(key)}['\"]\s*\]", corpus
        )
    ]
    if orphans:
        problems.append(
            f"pinned in {GROUP_VARS} `platform_chart_versions` but consumed by "
            f"nothing in {PLATFORM_TASKS}/: {', '.join(orphans)}.\n"
            f"        FIX: delete the pin (the service is gone) or add "
            f"`--version {{{{ platform_chart_versions.<key> }}}}` to its "
            f"`helm upgrade --install`. An unpinned install turns an unrelated "
            f"deploy into an uncontrolled upgrade of somebody else's service."
        )
    return problems


CHECKS = [
    ("dns.ts PRIVATE_HOSTS == group_vars private hostnames", check_private_hosts),
    ("infisical-vars.py vars == preflight.yml asserts", check_secret_keys),
    ("traefik trustedIPs == rate-limit excludedIPs", check_traefik_trusted_ips),
    ("platform_chart_versions pins are all consumed", check_chart_version_pins),
]


def main():
    # GitHub renders `::error::` as an annotation on the failing step; a plain
    # line is fine everywhere else. (Same convention as infisical-vars.py.)
    annotate = bool(os.environ.get("GITHUB_ACTIONS"))
    failed = 0

    for title, check in CHECKS:
        try:
            problems = check()
        except SyncError as exc:
            problems = [f"CANNOT CHECK — {exc}"]
        if problems:
            failed += 1
            print(f"FAIL  {title}")
            for problem in problems:
                prefix = "::error::" if annotate else ""
                print(f"      {prefix}{problem}")
        else:
            print(f"PASS  {title}")

    if failed:
        print(
            f"\n{failed} of {len(CHECKS)} sync assertions failed. Each pair "
            f"above is one fact written in two files on purpose (two different "
            f"consumers); the comment saying 'keep in sync' is not a check — "
            f"this script is.",
            file=sys.stderr,
        )
        return 1
    print(f"\nAll {len(CHECKS)} sync assertions hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
