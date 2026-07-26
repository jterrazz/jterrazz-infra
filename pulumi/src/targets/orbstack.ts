import * as pulumi from "@pulumi/pulumi";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

/**
 * OrbStack-hosted VM running the k3s + platform stack, wrapped around the
 * `orbctl` CLI because Pulumi has no first-party OrbStack provider.
 *
 * The VM must NOT be isolated: isolation drops CAP_SYS_ADMIN, which breaks
 * kubelet's tmpfs `noswap` mount for projected service-account tokens
 * (k8s >= 1.31). Non-isolated mode also auto-mounts the Mac filesystem at
 * `/mnt/mac`, which is what the bindMounts below rely on.
 *
 * DEFERRED: reimplementing on `local.Command` from @pulumi/command would
 * delete most of this file, but changing the resource type changes its URN,
 * so Pulumi would destroy and recreate the VM. It waits for a repave.
 */

/**
 * Not passed to orbctl: `--mount` requires isolated mode. create() only
 * ensures the dir exists on the Mac; the Ansible base role decides and
 * symlinks the VM-side path.
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

// The subset of `orbctl info --format json` this depends on, declared so an
// upstream schema change surfaces at parse time rather than silently.
interface OrbInfoJSON {
    record: {
        name: string;
        image: { distro: string; version: string; arch: string };
        state: string;
    };
    ip4: string;
}

// OrbStack's SSH key path is well-known and not configurable.
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
        return JSON.parse(orbctl(["info", name, "--format", "json"])) as OrbInfoJSON;
    } catch {
        // `orbctl info` exits non-zero when the VM doesn't exist. We treat
        // any read failure as "gone"; Pulumi's diff engine handles the rest.
        return null;
    }
}

const orbStackVMProvider: pulumi.dynamic.ResourceProvider = {
    async create(inputs: OrbCreateInputs): Promise<pulumi.dynamic.CreateResult> {
        // No --isolated (see the file header) and no `-u root`: OrbStack
        // 2.2.0 broke `orbctl create -u root` — its setup runs
        // `usermod --uid 501 root`, which fails against PID 1. The VM gets
        // the default macOS-named user; Ansible connects as `root@<vm>@orb`.
        const args = ["create", "-a", inputs.arch];

        // Without this the Ansible-side symlink target dangles and every k8s
        // hostPath mount fails at first pod schedule.
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
        // Stable across reads, which Pulumi requires: orbctl enforces VM name
        // uniqueness within a host.
        return { id: inputs.name, outs };
    },

    async read(id: string, props: OrbCreateOutputs): Promise<pulumi.dynamic.ReadResult> {
        const info = readVM(id);
        if (!info) {
            // An UNDEFINED id is how a dynamic provider says "gone", so
            // refresh drops it from state and the next up recreates it.
            // `{ id, props: {} }` instead means "still here, all properties
            // now empty", which leaves a phantom VM in state.
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
        // --force skips the interactive confirm; a missing VM is success.
        try {
            orbctl(["delete", "--force", id]);
        } catch (err) {
            const e = err as { message: string };
            if (!/not\s+exist|not\s+found/i.test(e.message)) throw err;
        }
    },

    // Every property is replace-on-change: OrbStack cannot change
    // distro/arch/mounts in-place, so destroy + recreate is the only honest
    // path. This is what makes deleteBeforeReplace below necessary.
    async diff(_id: string, oldProps: OrbCreateOutputs, newProps: OrbCreateInputs): Promise<pulumi.dynamic.DiffResult> {
        const replaces: string[] = [];
        for (const key of ["name", "distro", "version", "arch"] as const) {
            if (oldProps[key] !== newProps[key]) replaces.push(key);
        }
        // Compare bind mounts by their Mac-side sources only. Only `source`
        // has any effect (the VM-side path is Ansible's decision), and stored
        // state may carry extra fields from older schema versions of this
        // provider — a strict object compare would then order a VM
        // replacement over a field nothing reads.
        const sources = (m?: BindMount[]) => JSON.stringify((m ?? []).map((b) => b.source));
        if (sources(oldProps.bindMounts) !== sources(newProps.bindMounts)) {
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
            // Declared so TypeScript sees them; Pulumi fills them from the
            // provider's create/read return.
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
 * MACHINE_NAME is the cluster's identity in three places at once: the
 * `orbctl list` name, the Ansible `inventory_hostname`, and the Tailscale
 * hostname every private CNAME in dns.ts resolves to. Keep it and
 * distro/version/arch hardcoded — as stack config, a stack that omitted a key
 * booted a VM under the wrong identity and broke every private hostname.
 * `trixie` in particular MUST stay explicit: Debian is the one distro whose
 * bare OrbStack image name resolves to the PREVIOUS stable, and every Ansible
 * role here is Debian-13-native.
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
            // The Ansible base role symlinks /var/lib/k8s-data here, so every
            // PV's data survives `pulumi destroy && pulumi up`: the VM goes,
            // the Mac dir stays.
            { source: dataPathOnMac },
        ],
    }, {
        // REQUIRED. Every input change is a replacement (see diff above) and
        // VM names are unique within OrbStack, so Pulumi's default
        // create-before-delete would try to create the new VM while the old
        // one still holds the name and fail with "machine already exists".
        // Safe because the data lives on the Mac side of the bind mount.
        deleteBeforeReplace: true,
    });

    return { tailscaleHostname: pulumi.output(MACHINE_NAME) };
}
