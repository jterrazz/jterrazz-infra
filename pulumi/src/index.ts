import { createMachine } from "./targets/orbstack";
import { createPrivateDnsRecords } from "./dns";

/**
 * The cluster's infrastructure: one OrbStack VM on the dev Mac, plus the
 * Cloudflare DNS records that point the private hostnames at it.
 *
 * SINGLE TARGET. This file used to dispatch on a `target` stack config
 * between an OrbStack VM and a Hetzner cax21 VPS, with a `MachineOutputs`
 * interface (targets/types.ts) keeping the two interchangeable and a
 * `manageDns` flag deciding which of the two stacks owned the DNS records.
 * Only OrbStack was ever actually running; the Hetzner half cost a provider
 * dependency, an unused stack, a config knob, and — the real price — a
 * permanent "which one am I looking at?" tax on every file downstream.
 *
 * TO BRING HETZNER BACK: `docs/hetzner.md` records the shape it had, and the
 * implementation is intact in git history — `git log --all -- pulumi/src/targets/hetzner.ts`,
 * last present at commit 91d3ac9. Resurrecting it means restoring that file,
 * the `MachineOutputs` interface it implemented, the target dispatch here,
 * the `@pulumi/hcloud` + `@pulumi/tls` dependencies, and the `manageDns`
 * guard below — which existed so that testing one cluster could not repoint
 * production hostnames mid-experiment. Do NOT skip that guard: with two
 * stacks live, whichever one runs `pulumi up` last silently owns every
 * private CNAME.
 *
 * There is deliberately no `sshHost` / `sshPrivateKey` output any more. They
 * existed for Hetzner, where Ansible had to be handed a freshly generated key
 * and a public IPv4. OrbStack is reached through its own SSH proxy
 * (`root@jterrazz-infrastructure@orb`), so the inventory needs nothing from
 * Pulumi.
 */
const machine = createMachine();

createPrivateDnsRecords(machine.tailscaleHostname);

/**
 * The cluster's identity in the tailnet — the name every private CNAME
 * resolves to and the host `ssh root@<name>@orb` reaches. It is a constant
 * now that the machine name is hardcoded, but it is exported because it is
 * the one fact about this stack worth reading back out of it, and because
 * `dns.ts` is downstream of the same value.
 */
export const tailscaleHostname = machine.tailscaleHostname;
