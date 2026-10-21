# 06 – Upgrade: Image Factory, system extensions, A/B boot and Kubernetes

## Purpose

Talos is image-based: you do not install packages, you replace the complete system image. This stage starts
a cluster one step behind and upgrades it: Talos to the next patch release with a system extension, then
Kubernetes to the next minor release. You also roll back a node.

When you complete this stage, you know:

- What a schematic is, and how the Image Factory makes boot images and installer images from it.
- How a system extension gets into Talos, and how to find the schematic of a running node.
- The sequence of `talosctl upgrade`: install, drain, reboot, uncordon.
- How the A/B boot entries make `talosctl rollback` possible.
- How `talosctl upgrade-k8s` upgrades Kubernetes, independently of Talos.

## Concepts

### Schematic and Image Factory

A *schematic* is a small YAML file with the customizations of a Talos image: system extensions, extra kernel
arguments, META values and an overlay (for single board computers). The Image Factory computes an ID from the
content. With the ID and a Talos version, it makes all boot assets on request:

```
 schematic.yaml --POST /schematics--> ID 9a7f...c1
                                        |
     https://factory.talos.dev/image/<ID>/<version>/metal-amd64.iso      boot media (ISO, disk images, PXE)
     factory.talos.dev/metal-installer/<ID>:<version>                    installer image (install, upgrade)
```

- The installer image contains only the system extensions of the schematic. Extra kernel arguments and META
  values are only in the boot media.
- Use the same schematic for the boot media and for the installer image. Else, the extensions change at the
  first install.
- The schematic without customizations has the ID `3765...b4ba`. Talos 1.14 publishes no
  `ghcr.io/siderolabs/installer` image: the installer images come only from the Image Factory.

### System extensions

A system extension adds files to the root file system (kernel modules, firmware, services). Talos does not
download extensions at runtime: the installer image puts them into the boot image. To add or remove an
extension, you upgrade the node to an installer image with a different schematic.

The Image Factory adds a virtual extension with the name `schematic` and the schematic ID as its version.
Thus, `talosctl get extensions` shows which schematic a node runs.

### A/B boot entries

On a UEFI system, Talos 1.14 uses systemd-boot. Each install or upgrade writes a boot image (UKI: kernel,
initramfs and kernel command line in one EFI file) to the EFI partition. Talos keeps the running image and the
previous one:

```
 EFI partition before the upgrade        after the upgrade                 after a rollback
 +------------------------------+        +------------------------------+  +------------------------------+
 | Talos-v1.14.3.efi  (default) |        | Talos-v1.14.3.efi            |  | Talos-v1.14.3.efi  (default) |
 |                              |   -->  | Talos-v1.14.4.efi  (default) |  | Talos-v1.14.4.efi            |
 +------------------------------+        +------------------------------+  +------------------------------+
```

If the new image cannot boot, Talos boots the previous one. `talosctl rollback` sets the previous entry as
the default and reboots. The configuration (STATE) and the data (EPHEMERAL) do not change.

### Upgrade sequence

`talosctl upgrade` (Talos 1.13 and later) does these steps:

```
 talosctl                                   node
    | 1. Upgrade(image) ------------------>  pull the installer image, run it:
    |    <-- progress, "upgrade completed"    write the new UKI, set it as default (the node still runs)
    | 2. drain: cordon, evict the pods
    | 3. Reboot ------------------------------>  kexec into the new kernel (no firmware boot)
    |    <-- wait until the node is up
    | 4. uncordon
```

- With `--no-reboot`, `talosctl` does only step 1. The next reboot activates the new image.
- `--drain=false` skips steps 2 and 4.

### Kubernetes upgrade

A Talos upgrade does not change the Kubernetes version. `talosctl upgrade-k8s` upgrades Kubernetes in this
sequence: pre-pull the images, then for each control plane node the static pods (`kube-apiserver`,
`kube-controller-manager`, `kube-scheduler`), then `kubelet` on all nodes, then the bootstrap manifests
(`kube-proxy`, CoreDNS, ...). It changes the machine configuration of each node through the Talos API.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `upgrade` |
| Provisioner | QEMU, preset `iso` |
| Nodes | `upgrade-controlplane-1` (10.5.6.2), `upgrade-worker-1` (10.5.6.3) |
| Network | bridge, `10.5.6.0/24`, gateway and load balancer `10.5.6.1` |
| Talos at the start | the patch release before the labs version (for example v1.14.3), no extensions |
| Kubernetes at the start | the minor release before the talosctl default (for example 1.36.x) |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=upgrade`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `check` and `down`. |
| `mise-tasks/up` | Starts the cluster with the previous Talos patch release and the previous Kubernetes minor release. |
| `schematic.yaml` | Schematic with the official extension `siderolabs/qemu-guest-agent`. |

## Procedure

Do the steps in the stage folder (`06-upgrade/`).

### Step 1: Start the lab

```bash
mise run up
```

Expected output at the start and at the end (example):

```
Talos v1.14.3, Kubernetes 1.36.4
...
Client:
Talos v1.14.4
Server:
	NODE:        10.5.6.2
Talos v1.14.3
...
NODE       NAMESPACE   TYPE              ID   VERSION   NAME        VERSION
10.5.6.2   runtime     ExtensionStatus   0    1         schematic   376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
10.5.6.3   runtime     ExtensionStatus   0    1         schematic   376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
...
NAME                     STATUS   ROLES           AGE   VERSION   ...
upgrade-controlplane-1   Ready    control-plane   2m    v1.36.4   ...
upgrade-worker-1         Ready    <none>          2m    v1.36.4   ...
```

If the Talos version of the labs is a `.0` release, the cluster starts with the same version. Then the
upgrade in step 4 changes only the schematic.

### Step 2: Examine the boot entry and the security state

```bash
talosctl get bootedentries
talosctl get securitystate -o yaml | yq .spec
```

- `bootedentries` shows the UKI file that systemd-boot started, for example `Talos-v1.14.3.efi`.
- `securitystate` shows `bootedWithUKI: true` and `secureBoot: false` (stage 09 enables Secure Boot).

### Step 3: Make the schematic

1. Upload the schematic and keep its ID:

   ```bash
   cat schematic.yaml
   SCHEMATIC=$(curl -fsS -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
   echo "$SCHEMATIC"
   ```

2. Upload it again. The ID does not change:

   ```bash
   curl -fsS -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
   ```

3. Set the target image:

   ```bash
   TO=$(talosctl version --client | awk '/Tag:/ {print $2; exit}'); echo "$TO"
   IMAGE="factory.talos.dev/metal-installer/$SCHEMATIC:$TO"; echo "$IMAGE"
   ```

   If `TALOS_VERSION` is set (see the main README), use `TO=v${TALOS_VERSION#v}`.

### Step 4: Upgrade the worker

1. In a second terminal, watch the node:

   ```bash
   kubectl get nodes --watch
   ```

2. Upgrade:

   ```bash
   talosctl -n 10.5.6.3 upgrade --image "$IMAGE"
   ```

   Expected output (example, part):

   ```
   10.5.6.3: pulling factory.talos.dev/metal-installer/9a7f...:v1.14.4 ...
   10.5.6.3: upgrade completed
   cordoning node upgrade-worker-1
   evicting pod kube-system/coredns-...
   ...
   watching nodes: [10.5.6.3]
       * 10.5.6.3: post check passed
   uncordoning node upgrade-worker-1
   ```

   In the second terminal, the node changes to `Ready,SchedulingDisabled`, then `NotReady`, then `Ready`.

3. Examine the result:

   ```bash
   talosctl -n 10.5.6.3 version --short
   talosctl -n 10.5.6.3 get extensions
   talosctl -n 10.5.6.3 get bootedentries
   talosctl -n 10.5.6.3 service ext-qemu-guest-agent
   ```

   - The server version is the new one.
   - There are two extensions: `qemu-guest-agent` and `schematic` with the new ID.
   - The booted entry is the new UKI file.
   - The service `ext-qemu-guest-agent` is `Running`.

### Step 5: Upgrade the control plane node

```bash
talosctl -n 10.5.6.2 upgrade --image "$IMAGE"
```

The cluster has only one control plane node, and one etcd member. While the node reboots, the Kubernetes API
is not available. With three control plane nodes (stage 07), upgrade them one at a time.

### Step 6: Upgrade Kubernetes

1. Show the plan:

   ```bash
   talosctl -n 10.5.6.2 upgrade-k8s --dry-run
   ```

   `--from` is the current version (detected). `--to` is the default of `talosctl`.

2. Do the upgrade:

   ```bash
   talosctl -n 10.5.6.2 upgrade-k8s
   ```

   Expected output (example, part):

   ```
   automatically detected the lowest Kubernetes version 1.36.4
   discovered controlplane nodes ["10.5.6.2"]
   discovered worker nodes ["10.5.6.3"]
   > "10.5.6.2": pre-pulling registry.k8s.io/kube-apiserver:v1.37.1
   ...
   updating "kube-apiserver" to version "1.37.1"
    > "10.5.6.2": starting update
   ...
   updating kubelet to version "1.37.1"
   ...
   updating manifests
   ```

3. Check the cluster:

   ```bash
   mise run check
   ```

   All nodes show the new Talos version, the extension and the new Kubernetes version.

## Experiments

Do the experiments after the procedure, in the sequence below.

### Experiment 1: Roll back the worker

1. Roll back:

   ```bash
   talosctl -n 10.5.6.3 rollback
   ```

2. When the node is `Ready` again, examine it:

   ```bash
   talosctl -n 10.5.6.3 version --short
   talosctl -n 10.5.6.3 get extensions
   talosctl -n 10.5.6.3 get bootedentries
   kubectl get node upgrade-worker-1
   ```

   - Talos and the extensions are as before the upgrade (no `qemu-guest-agent`).
   - Kubernetes still shows the new kubelet version: the kubelet version is in the machine configuration
     (STATE), and a rollback does not change STATE.

3. Upgrade the worker again:

   ```bash
   talosctl -n 10.5.6.3 upgrade --image "$IMAGE"
   ```

### Experiment 2: Install now, reboot later

1. Upgrade the worker to the same image without a reboot:

   ```bash
   talosctl -n 10.5.6.3 upgrade --image "$IMAGE" --no-reboot
   talosctl -n 10.5.6.3 get bootedentries
   ```

   The node still runs the old entry. The new image is the default for the next boot. The node was not
   drained.

2. Reboot when it is convenient:

   ```bash
   talosctl -n 10.5.6.3 reboot
   talosctl -n 10.5.6.3 get bootedentries
   ```

   Each install writes a new UKI file. If a file for the same version exists, the new file gets a suffix,
   for example `Talos-v1.14.4~1.efi`.

### Experiment 3: Use the QEMU guest agent

The QEMU provisioner connects a virtio serial port of each VM to a UNIX socket in the state folder. The guest
agent in the VM answers on this port.

1. Send two commands to the worker:

   ```bash
   echo '{"execute":"guest-ping"}' | sudo socat -t 2 - UNIX-CONNECT:build/state/upgrade/upgrade-worker-1.sock
   echo '{"execute":"guest-get-osinfo"}' | sudo socat -t 2 - UNIX-CONNECT:build/state/upgrade/upgrade-worker-1.sock
   ```

   Expected output (example):

   ```
   {"return": {}}
   {"return": {"name": "Talos", "kernel-release": "6.18...", "version-id": "v1.14.4", ...}}
   ```

   A hypervisor uses the guest agent, for example, to read the IP addresses of a VM and to shut it down
   gracefully.

### Experiment 4: Upgrade to an image that does not exist

```bash
talosctl -n 10.5.6.3 upgrade --image factory.talos.dev/metal-installer/0000000000000000000000000000000000000000000000000000000000000000:v1.14.4
```

The command fails at the pull, before the drain. The node does not reboot and nothing changes. Talos checks
the installer image before it changes the boot entries.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `curl` to `/schematics` fails. | No access to `factory.talos.dev`. | Check the internet access and the proxy settings of the host. |
| The upgrade fails with `error validating installer image`. | Wrong schematic ID or version, or the node cannot reach the registry. | Check `$IMAGE`. `talosctl -n <node> image pull --namespace system "$IMAGE"` shows the pull error. |
| The drain does not end. | A PodDisruptionBudget blocks the eviction. | Wait for `--drain-timeout` (5 minutes), or delete the blocking pod. |
| After the upgrade, `qemu-guest-agent` is missing. | The installer image has the empty schematic. | Check `talosctl get extensions`. Upgrade again with `$IMAGE`. |
| `upgrade-k8s` fails with `version skew`. | The jump is more than one minor release. | Upgrade one minor release at a time: `--to 1.<n+1>.x`. |
| `socat: command not found`. | `socat` is not installed on the host. | Install `socat`. |

## Clean up

```bash
mise run down
```

## References

- Upgrade Talos: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos
- Image Factory: https://docs.siderolabs.com/talos/v1.14/learn-more/image-factory
- System extensions: https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions
- Boot loader: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/bootloader
- Upgrade Kubernetes: https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes
- Extension catalog: https://github.com/siderolabs/extensions
