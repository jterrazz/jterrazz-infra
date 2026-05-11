import * as pulumi from "@pulumi/pulumi";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

/**
 * Outputs the machine resource exposes to the rest of the pipeline.
 * Ansible reads sshHost/sshPrivateKey from Pulumi state; deploy.sh and
 * dns.ts read tailscaleHostname.
 */
export interface MachineOutputs {
    /** Hostname Ansible feeds into `ansible_host`. For OrbStack this is
     *  the VM name reached through the OrbStack SSH proxy. */
    sshHost: pulumi.Output<string>;
    /** The OrbStack-managed SSH private key file's contents; marked
     *  secret so Ansible can consume it without leaking into Pulumi
     *  preview/up output. */
    sshPrivateKey: pulumi.Output<string>;
    /** Hostname the VM registers with Tailscale (= the Cloudflare CNAME
     *  target for private hostnames managed by `pulumi/src/dns.ts`). */
    tailscaleHostname: pulumi.Output<string>;
    /** Free-form status string surfaced via `pulumi stack output`. */
    status: pulumi.Output<string>;
    /** Cosmetic logical name (matches the orbctl VM name). */
    name: pulumi.Output<string>;
}

/**
 * OrbStack-hosted Linux VM running the same k3s + platform stack the
 * cluster has always run. No first-party OrbStack provider exists for
 * Pulumi, so we wrap the `orbctl` CLI with a custom dynamic resource.
 * Three operations matter:
 *
 *  - **Create** calls `orbctl create`. The VM is intentionally NOT
 *    isolated: isolation drops CAP_SYS_ADMIN inside the VM, which breaks
 *    kubelet's tmpfs `noswap` mount for projected service-account tokens
 *    (k8s ≥1.31). The downside of non-isolated mode is that OrbStack
 *    auto-mounts the Mac filesystem at `/mnt/mac`; we use that exact
 *    behaviour for data persistence (see the bindMounts comment below).
 *  - **Read** calls `orbctl info <name> --format json` to refresh state.
 *  - **Delete** calls `orbctl delete --force <name>`.
 *
 * Update is intentionally implemented as recreate (replace-on-change for
 * every input). Mounts, distro, arch can't be changed in-place on a live
 * OrbStack VM, and re-running create is cheap (~20s).
 */

/**
 * Logical bind mount declaration. Because OrbStack `--mount` requires
 * isolated mode (which breaks kubelet), we don't pass these to orbctl;
 * instead the create step ensures the source dir exists on the Mac, and
 * Ansible's storage role symlinks the VM-side path to
 * `/mnt/mac/<source>` so the VM sees the Mac folder at `destination`.
 */
export interface BindMount {
    /** Absolute path on the Mac. */
    source: string;
    /** Absolute path inside the VM. */
    destination: string;
}

export interface OrbStackVMArgs {
    /** Machine name shown in `orbctl list`. Also the Ansible `inventory_hostname`. */
    name: pulumi.Input<string>;
    /** Linux distro (alpine | ubuntu | debian | …). */
    distro: pulumi.Input<string>;
    /** Optional distro version (e.g. "noble" for Ubuntu 24.04). */
    version?: pulumi.Input<string>;
    /** Architecture (arm64 | amd64). Defaults to host arch. */
    arch?: pulumi.Input<string>;
    /** Default user inside the VM. `orbctl` defaults to the macOS user; we use `root` for Ansible. */
    user?: pulumi.Input<string>;
    /** Host folders to mount into the VM. */
    bindMounts?: pulumi.Input<pulumi.Input<BindMount>[]>;
}

interface OrbCreateInputs {
    name: string;
    distro: string;
    version?: string;
    arch?: string;
    user?: string;
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
        config: {
            isolated: boolean;
            default_username: string;
            mounts: { source: string; destination: string }[];
        };
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
        const out = execFileSync("orbctl", ["info", name, "--format", "json"], {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
        });
        return JSON.parse(out) as OrbInfoJSON;
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
        // Note: no --isolated flag. Isolated VMs lose CAP_SYS_ADMIN, which
        // breaks kubelet (tmpfs noswap mounts, swapoff, etc.). The price is
        // that OrbStack auto-mounts the whole Mac home at /mnt/mac/...; we
        // turn that into a feature by having Ansible symlink the bindMount
        // destinations into /mnt/mac/<source>.
        const args = ["create"];
        if (inputs.arch) args.push("-a", inputs.arch);
        if (inputs.user) args.push("-u", inputs.user);
        // Ensure Mac-side source dirs exist; otherwise the symlink target
        // (resolved Ansible-side) would dangle and k8s hostPath mounts would
        // fail with confusing errors at first pod schedule.
        for (const m of inputs.bindMounts ?? []) {
            if (!fs.existsSync(m.source)) {
                fs.mkdirSync(m.source, { recursive: true });
            }
        }
        const image = inputs.version ? `${inputs.distro}:${inputs.version}` : inputs.distro;
        args.push(image, inputs.name);

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
            // Returning empty props tells Pulumi the resource is gone; the
            // next `up` will recreate it.
            return { id, props: {} };
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
        for (const key of ["name", "distro", "version", "arch", "user"] as const) {
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

/** Build the cluster machine outputs. Reads its config from the
 *  `orbstack:` namespace in the stack config (see Pulumi.local.yaml). */
export function createMachine(): MachineOutputs {
    const config = new pulumi.Config("orbstack");
    // Default name keeps the VM distinct in `orbctl list` even if someone
    // forgets to set `orbstack:machineName`. Pulumi.local.yaml overrides
    // this to "jterrazz-infra" — the canonical Tailscale identity.
    const machineName = config.get("machineName") || "jterrazz-orbstack";
    const distro = config.get("distro") || "ubuntu";
    const version = config.get("version") || "noble";
    const arch = config.get("arch") || "arm64";
    const dataPathOnMac =
        config.get("dataPath") || path.join(os.homedir(), ".jterrazz-infra", "data");

    const vm = new OrbStackVM(machineName, {
        name: machineName,
        distro,
        version,
        arch,
        user: "root",
        bindMounts: [
            // k3s storage lives at /var/lib/k8s-data; Ansible's storage
            // role symlinks it to /mnt/mac/<dataPath> so data survives
            // `pulumi destroy && pulumi up` (VM goes, Mac dir stays).
            { source: dataPathOnMac, destination: "/var/lib/k8s-data" },
        ],
    });

    return {
        sshHost: vm.name,
        sshPrivateKey: pulumi.secret(vm.sshKeyPath.apply((p) => fs.readFileSync(p, "utf8"))),
        tailscaleHostname: pulumi.output(machineName),
        status: vm.state,
        name: vm.name,
    };
}
