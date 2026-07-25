# Resurrecting a Hetzner target

This repo used to be dual-mode: the same `site.yml` could configure either a
Hetzner cax21 VPS (`jterrazz/production`) or the OrbStack VM
(`jterrazz/local`). The Hetzner half was removed — it had been unused since the
May 2026 swap to OrbStack, and keeping it meant a `deployment_target` branch in
every role plus a second inventory nobody ran.

Nothing was deleted destructively: the full dual-mode implementation is in git
history, in the commit immediately **before** the one that added this file
(`git log --diff-filter=D --name-only -- ansible/inventories/production` finds
the removal commit; `git show <sha>^:<path>` prints any file as it was).

The pieces you would restore:

- `pulumi/src/targets/hetzner.ts` and its `targets/types.ts` wiring — the
  hcloud Server + SSH key + firewall, `image: debian-13` (the genericcloud
  arm64 image; do **not** take Hetzner's default, it is the previous stable).
- `ansible/inventories/production/hosts.yml` — group `cluster`, host
  `jterrazz-vps`, `ansible_host` and `ansible_ssh_private_key_file` passed in
  from Pulumi outputs (`sshHost`, `sshPrivateKey --show-secrets`).
- The `deployment_target` var and its `when:` branches (`/dev/kmsg` backfill
  and the `/var/lib/k8s-data` Mac symlink are OrbStack-only; the plain
  `mkdir /var/lib/k8s-data` is the Hetzner path), plus `ansible_host` back in
  the k3s TLS SAN list (on Hetzner it is a real public IP).
- `scripts/deploy.sh`'s positional target + the SSH-key tempfile helper.

Stack init (only `Pulumi.local.yaml` is committed):

```bash
cd pulumi
pulumi stack init jterrazz/production
pulumi config set jterrazz-infrastructure:target hetzner
pulumi config set --secret hcloud:token <hetzner-api-token>
pulumi config set --secret cloudflare:apiToken <cloudflare-dns-edit-token>
pulumi up
```

**DNS / `manageDns`**: only ONE stack may have
`jterrazz-infrastructure:manageDns: "true"` at a time — it owns the private
`*.jterrazz.com` CNAMEs in `pulumi/src/dns.ts`. Flip it off on `local` before
turning it on for `production`, or the two stacks fight over the same records.
After a swap, run `make redeploy-apps`: every app image lives in the old
cluster's registry and has to be re-pushed.
