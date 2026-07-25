import * as pulumi from "@pulumi/pulumi";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

/**
 * OrbStack-hosted Linux VM running the k3s + platform stack. No first-party
 * OrbStack provider exists for Pulumi, so we wrap the `orbctl` CLI with a
 * custom dynamic resource. Three operations matter:
 *
 *  - **Create** calls `orbctl create`. The VM is intentionally NOT
 *    isolated: isolation drops CAP_SYS_ADMIN inside the VM, which breaks
 *    kubelet's tmpfs `noswap` mount for projected service-account tokens
 *    (k8s >= 1.31). The downside of non-isolated mode is that OrbStack
 *    auto-mounts the Mac filesystem at `/mnt/mac`; we use that exact
 *    behaviour for data persistence (see the bindMounts comment below).
 *  - **Read** calls `orbctl info <name> --format json` to refresh state.
 *  - **Delete** calls `orbctl delete --force <name>`.
 *
 * Update is intentionally implemented as recreate (replace-on-change for
 * every input). Mounts, distro and arch can't be changed in-place on a live
 * OrbStack VM, and re-running create is cheap (~20s).
 *
 * DEFERRED: rewriting this on top of `local.Command` from
 * @pulumi/command would delete most of this file, but swapping the resource
 * type changes its URN — Pulumi would destroy the VM and create a new one.
 * That is a repave, so it waits for a moment when one is happening anyway.
 */

/**
 * Logical bind mount declaration. OrbStack's `--mount` requires isolated mode
 * (which breaks kubelet), so we do NOT pass these to orbctl. Instead the
 * create step ensures the source dir exists on the Mac and Ansible's storage
 * role symlinks the VM-side path to `/mnt/mac/<source>`.
 *
 * `source` is the only field: a `destination` used to be declared here too,
 * but nothing ever read it — the VM-side path is decided by Ansible, not by
 * this resource, so carrying it here just invited someone to change it and
 * expect something to happen.
 */
export interface BindMount {
    /** Absolute path on the Mac. */
    source: string;
}

export interface OrbStackVMArgs {
    /** Machine name shown in `orbctl list`. Also the Ansible `inventory_hostname`. */
    name: pulumi.Input<string>;
    /** Linux distro image, e.g. "debian". */
    distro: pulumi.Input<string>;
    /** Distro version, e.g. "trixie" for Debian 13. */
    version: pulumi.Input<string>;
    /** Architecture (arm64 | amd64). */
    arch: pulumi.Input<string>;
    /** Host folders whose existence the VM depends on. */
    bindMounts?: pulumi.Input<pulumi.Input<BindMount>[]>;
}

interface OrbCreateInputs {
    name: string;
    distro: string;
    version: string;
    arch: string;
    bindMounts?: BindMount[];
}

interface OrbCreateOutputs extends OrbCreateInputs {
    ip4: string;
    state: string;
    /** Path to the OrbStack-managed SSH private key on the host Mac. */
    sshKeyPath: string;
}

// orbctl's `info --format json` schema (subset we use). Documented here to
// keep the parse close to the shape we depend on; if OrbStack ever ships a
// schema change the failure surfaces at parse time, not silently.
interface OrbInfoJSON {
    record: {
        name: string;
        image: { distro: string; version: string; arch: string };
        state: string;
    };
    ip4: string;
}

// We resolve $HOME at module-load time. OrbStack's SSH key lives at a
// well-known path and isn't configurable, so encoding it here is correct.
const ORBSTACK_SSH_KEY = path.join(os.homedir(), ".orbstack", "ssh", "id_ed25519");

function orbctl(args: string[]): string {
    try {
        return execFileSync("orbctl", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (err: unknown) {
        const e = err as { stderr?: Buffer; message?: string };
        const stderr = e.stderr?.toString() ?? "";
        throw new Error(`orbctl ${args.join(" ")} failed: ${stderr || e.message}`);
    }
}

function readVM(name: string): OrbInfoJSON | null {
    try {
        // Same orbctl() wrapper as every other call — this used to duplicate
        // the execFileSync invocation, so the two could (and did) drift.
        return JSON.parse(orbctl(["info", name, "--format", "json"])) as OrbInfoJSON;
    } catch {
        // `orbctl info` exits non-zero when the VM doesn't exist. We treat
        // any read failure as "gone"; Pulumi's diff engine handles the rest.
        return null;
    }
}

const orbStackVMProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs: OrbCreateInputs): Promise<pulumi.dynamic.CreateResult> {
        // Build the argv ourselves rather than `orbctl create … | sh` so a
        // malformed input fails loudly rather than silently mangling args.
        //
        // Note: no --isolated flag. Isolated VMs lose CAP_SYS_ADMIN, which
        // breaks kubelet (tmpfs noswap mounts, swapoff, etc.). The price is
        // that OrbStack auto-mounts the whole Mac home at /mnt/mac/...; we
        // turn that into a feature by having Ansible symlink the bindMount
        // sources into place.
        //
        // Also no `-u root`: OrbStack 2.2.0 broke `orbctl create -u root` —
        // its initial setup runs `usermod --uid 501 root`, which fails with
        // "user root is currently used by process 1". The VM is created with
        // the default macOS-named user; root still exists and Ansible
        // connects to it explicitly via `root@<vm>@orb`.
        const args = ["create", "-a", inputs.arch];

        // Ensure Mac-side source dirs exist; otherwise the symlink target
        // (resolved Ansible-side) would dangle and k8s hostPath mounts would
        // fail with confusing errors at first pod schedule.
        for (const m of inputs.bindMounts ?? []) {
            if (!fs.existsSync(m.source)) {
                fs.mkdirSync(m.source, { recursive: true });
            }
        }

        args.push(`${inputs.distro}:${inputs.version}`, inputs.name);
        orbctl(args);

        const info = readVM(inputs.name);
        if (!info) {
            throw new Error(`orbctl create succeeded but info ${inputs.name} returned nothing`);
        }

        const outs: OrbCreateOutputs = {
            ...inputs,
            ip4: info.ip4,
            state: info.record.state,
            sshKeyPath: ORBSTACK_SSH_KEY,
        };
        // Pulumi resource IDs must be stable across reads — the VM name fits
        // (orbctl enforces uniqueness within a host).
        return { id: inputs.name, outs };
    },

    async read(id: string, props: OrbCreateOutputs): Promise<pulumi.dynamic.ReadResult> {
        const info = readVM(id);
        if (!info) {
            // An UNDEFINED id is how a dynamic provider says "this resource no
            // longer exists"; `pulumi refresh` then drops it from state and the
            // next `up` recreates it. Returning `{ id, props: {} }` (the
            // previous behaviour) says instead "it still exists, and every
            // property is now empty" — so refresh kept a phantom VM in state
            // with a blank distro/arch, and the next up saw that as an
            // in-place-impossible change rather than a create.
            return { id: undefined };
        }
        return {
            id,
            props: {
                ...props,
                state: info.record.state,
                ip4: info.ip4,
                sshKeyPath: ORBSTACK_SSH_KEY,
            },
        };
    },

    async delete(id: string, _props: OrbCreateOutputs): Promise<void> {
        // --force skips the interactive confirm. orbctl errors if the VM is
        // missing; we ignore that path (already-gone is success for delete).
        try {
            orbctl(["delete", "--force", id]);
        } catch (err) {
            const e = err as { message: string };
            if (!/not\s+exist|not\s+found/i.test(e.message)) throw err;
        }
    },

    // Pulumi calls `diff` to decide create-replace vs in-place update. We
    // mark every property as replace-on-change because OrbStack doesn't
    // support changing distro/arch/mounts in-place — the only honest path
    // is destroy + recreate. Recreating is cheap (~20s).
    async diff(_id: string, oldProps: OrbCreateOutputs, newProps: OrbCreateInputs): Promise<pulumi.dynamic.DiffResult> {
        const replaces: string[] = [];
        for (const key of ["name", "distro", "version", "arch"] as const) {
            if (oldProps[key] !== newProps[key]) replaces.push(key);
        }
        if (JSON.stringify(oldProps.bindMounts) !== JSON.stringify(newProps.bindMounts)) {
            replaces.push("bindMounts");
        }
        return { replaces, changes: replaces.length > 0 };
    },
};

export class OrbStackVM extends pulumi.dynamic.Resource {
    public readonly name!: pulumi.Output<string>;
    public readonly ip4!: pulumi.Output<string>;
    public readonly state!: pulumi.Output<string>;
    public readonly sshKeyPath!: pulumi.Output<string>;

    constructor(name: string, args: OrbStackVMArgs, opts?: pulumi.CustomResourceOptions) {
        super(orbStackVMProvider, name, {
            // Output property declarations — Pulumi fills these from the
            // provider's create/read return. Listed here so TypeScript
            // knows about them.
            ip4: undefined,
            state: undefined,
            sshKeyPath: undefined,
            ...args,
        }, opts);
    }
}

/**
 * The one machine this stack manages.
 *
 * `MACHINE_NAME` is the cluster's identity in three places at once — the
 * `orbctl list` name, the Ansible `inventory_hostname`, and the Tailscale
 * hostname every private CNAME in dns.ts points at. It used to be an
 * `orbstack:machineName` config knob whose DEFAULT ("jterrazz-orbstack")
 * disagreed with the value every stack actually set, so reading it from
 * config was a trap: a stack that forgot the key would silently boot a VM
 * under the wrong tailnet identity and every private hostname would break.
 *
 * distro/version/arch are hardcoded for the same reason — they were config
 * knobs that no stack ever overrode, and two of the three are load-bearing:
 *   * `debian:trixie` — the version MUST stay explicit. Debian is the one
 *     distro where OrbStack's bare image name resolves to the PREVIOUS stable
 *     (bookworm/12), and the Ansible roles are Debian-13-native (deb822
 *     repositories, socket-activated sshd, systemd-resolved as a separate
 *     package).
 *   * `arm64` — the Mac is Apple Silicon; an amd64 VM would run under
 *     emulation.
 *
 * `dataPath` stays configurable: it is the one value that is genuinely
 * per-machine (where on THIS Mac the cluster's data lives).
 */
const MACHINE_NAME = "jterrazz-infrastructure";

export function createMachine(): { tailscaleHostname: pulumi.Output<string> } {
    const config = new pulumi.Config("orbstack");
    const dataPathOnMac =
        config.get("dataPath") || path.join(os.homedir(), ".jterrazz-infrastructure", "data");

    new OrbStackVM(MACHINE_NAME, {
        name: MACHINE_NAME,
        distro: "debian",
        version: "trixie",
        arch: "arm64",
        bindMounts: [
            // k3s storage lives at /var/lib/k8s-data; Ansible's storage
            // role symlinks it to /mnt/mac/<dataPath> so data survives
            // `pulumi destroy && pulumi up` (VM goes, Mac dir stays).
            { source: dataPathOnMac },
        ],
    }, {
        // Every input change is a replacement (see the provider's diff), and
        // the VM name is unique within OrbStack — Pulumi's default
        // create-before-delete replacement would try to create the new VM
        // while the old one still holds the name and fail with
        // "machine already exists". Delete first; the data lives on the Mac
        // side of the bind mount, so this is safe.
        deleteBeforeReplace: true,
    });

    return { tailscaleHostname: pulumi.output(MACHINE_NAME) };
}
