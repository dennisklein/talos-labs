# 05 – Install: from the ISO to an installed cluster

## Purpose

Stages 01 to 03 used Talos in Docker. A container has no disk, no boot loader and no install step. Stage 04
booted QEMU virtual machines (VMs) from the ISO, without an install. This stage also uses QEMU VMs. The VMs boot the Talos ISO without a machine configuration, and you do the
complete install procedure by hand, as on a bare metal server.

When you complete this stage, you know:

- What *maintenance mode* is, and what the insecure maintenance API permits.
- How to make a machine configuration with `talosctl gen secrets` and `talosctl gen config`.
- How `apply-config --insecure` installs Talos to a disk.
- Why the first control plane node needs `talosctl bootstrap`.
- The partitions on the system disk (EFI, META, STATE, EPHEMERAL) and what each one contains.
- How `talosctl reset` brings a node back to maintenance mode.

## Concepts

### Boot media and installed system

The ISO (or a PXE boot, or a disk image) contains a complete Talos system. It runs from RAM. Talos installs
itself to a disk only when it gets a machine configuration. The `UnattendedInstallConfig` document tells
Talos which disk to use and which *installer image* to run.

```
 ISO boot, no configuration               install                       boot from disk
 +---------------------------+   apply-config --insecure   +---------------------------+
 | Talos from RAM            |  ------------------------>  | Talos from /dev/vda       |
 | maintenance mode          |   1. pull installer image   | configuration in STATE    |
 | maintenance API :50000    |   2. partition /dev/vda     | Talos API :50000 (mTLS)   |
 | (TLS, no client auth)     |   3. write boot loader      | services start            |
 +---------------------------+   4. reboot                 +---------------------------+
```

The QEMU VMs boot in the sequence "disk, then CD-ROM". An empty disk is not bootable, so the first boot uses
the ISO. After the install, the VM boots from the disk.

### Maintenance mode

A node without a machine configuration starts the maintenance API on port 50000. The connection is
encrypted (TLS), but the client does not authenticate. Thus, `talosctl` needs the flag `--insecure`, and the
client gets only the role `os:reader` with some extra permissions:

| Operation | Permitted in maintenance mode |
|-----------|-------------------------------|
| `get` of non-sensitive resources (`disks`, `links`, `addresses`, ...) | Yes |
| `version` | Yes |
| `apply-config` | Yes. This is the purpose of maintenance mode. |
| `wipe disk` | Yes |
| `upgrade` | Yes (it installs a different version) |
| `get` of secrets, `read`, `logs`, `bootstrap`, `reset` | No |

Anybody who can connect to port 50000 of a node in maintenance mode can apply a configuration. Thus, apply
the configuration soon after the boot, and use a network that you trust.

### Secrets and configuration

`talosctl gen secrets` makes the *secrets bundle*: the certificate authorities (Talos API, Kubernetes,
etcd), the bootstrap token, the encryption key for Kubernetes secrets and the cluster ID and secret for
discovery. `talosctl gen config` makes three files from the bundle:

```
 secrets.yaml ---> gen config <cluster> <kubernetes endpoint> ---+--> controlplane.yaml
 (keep it safe:                                                  +--> worker.yaml
  all certificates come from it)                                 +--> talosconfig (client certificate, role os:admin)
```

If you lose `secrets.yaml`, you can make it again from `controlplane.yaml`
(`talosctl gen secrets --from-controlplane-config`). If you lose both, you cannot add nodes to the cluster.

### Bootstrap

etcd needs a first member. `talosctl bootstrap` tells *one* control plane node to make a new etcd cluster.
The other control plane nodes join it. Do the bootstrap only one time in the life of a cluster: a second
bootstrap on a different node makes a second etcd cluster (split brain). Talos refuses a bootstrap on a node
that has etcd data.

### System disk partitions

| Partition | Size (example) | Content |
|-----------|----------------|---------|
| `EFI` | about 1 GB | Boot loader (systemd-boot) and the Talos boot images (UKI): the running one and the previous one. |
| `META` | 1 MB | Small key-value data that the boot loader and Talos share, for example the upgrade state. |
| `STATE` | about 100 MB | The machine configuration and the node identity. |
| `EPHEMERAL` | rest of the disk | `/var`: etcd data, container images, kubelet data, logs. |

`reset` deletes STATE and EPHEMERAL: the node forgets its configuration and its data.

### QEMU topology

`talosctl cluster create qemu` makes a Linux bridge on the host and runs DHCP and DNS servers for the VMs.
It needs root. The labs run it with `sudo`.

```
 host
 +------------------------------------------------------------------------------+
 |  talosctl (sudo): bridge talos<id> 10.5.5.1/24, DHCP, DNS, load balancer :6443 |
 |                                                                              |
 |   +----------------------------+        +----------------------------+      |
 |   | VM install-controlplane-1  |        | VM install-worker-1        |      |
 |   | 10.5.5.2                   |        | 10.5.5.3                   |      |
 |   | /dev/vda 10 GiB (system)   |        | /dev/vda 10 GiB (system)   |      |
 |   | ISO in the CD-ROM drive    |        | /dev/vdb 6 GiB (extra)     |      |
 |   +----------------------------+        | ISO in the CD-ROM drive    |      |
 |                                         +----------------------------+      |
 |  talosctl, kubectl (as your user)  --->  10.5.5.2:50000, 10.5.5.2:6443        |
 +------------------------------------------------------------------------------+
```

- The VM processes and the servers run in the background. The VM consoles go to
  `build/state/install/<node>.log`.
- The load balancer on `10.5.5.1:6443` is for configurations that the provisioner makes. Your configuration
  in this stage uses `https://10.5.5.2:6443` directly.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `install` |
| Provisioner | QEMU, presets `iso` and `maintenance` |
| Nodes | `install-controlplane-1` (10.5.5.2), `install-worker-1` (10.5.5.3) |
| Network | bridge, `10.5.5.0/24`, gateway `10.5.5.1` |
| Disks | `/dev/vda` 10 GiB on each VM, `/dev/vdb` 6 GiB on the worker |
| Kubernetes endpoint | `https://10.5.5.2:6443` |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=install`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `check` and `down`. |
| `mise-tasks/up` | Starts the VMs in maintenance mode. Keeps the configuration of the provisioner in `build/provisioner/`. |
| `mise-tasks/install` | Steps 3 to 7 in one command. |
| `node-patches/controlplane-1.yaml` | `HostnameConfig` with the host name `install-controlplane-1`. |
| `node-patches/worker-1.yaml` | `HostnameConfig` with the host name `install-worker-1`. |

## Procedure

Do the steps in the stage folder (`05-install/`). The host must meet the QEMU requirements in the
[main README](../README.md#host-requirements).

### Step 1: Start the VMs

```bash
mise run up
```

The task asks for your `sudo` password. It downloads the ISO from the Image Factory (one time) and starts two
VMs. `cluster create` returns before the VMs have booted. Thus, the task waits until the maintenance API
answers on both VMs. The VMs stay in maintenance mode. Expected output at the end (example):

```
PROVISIONER           qemu
NAME                  install
NETWORK NAME          install
NETWORK CIDR          10.5.5.0/24
NETWORK GATEWAY       10.5.5.1
NETWORK MTU           1500
KUBERNETES ENDPOINT   https://10.5.5.1:6443

NODES:

NAME                     TYPE           IP         CPU    RAM      DISK
install-controlplane-1   controlplane   10.5.5.2   2.00   2.1 GB   10 GB
install-worker-1         worker         10.5.5.3   2.00   2.1 GB   10 GB

The VMs are in maintenance mode. Continue with step 2 of the README, or run 'mise run install'.
```

### Step 2: Examine the nodes in maintenance mode

1. Show the version. The flag `--insecure` uses the maintenance API:

   ```bash
   talosctl -n 10.5.5.2 version --insecure
   ```

2. Show the disks and the network links of the worker:

   ```bash
   talosctl -n 10.5.5.3 get disks --insecure
   talosctl -n 10.5.5.3 get links --insecure
   talosctl -n 10.5.5.3 get addresses --insecure
   ```

   Expected output of the first command (example):

   ```
   NODE   NAMESPACE   TYPE   ID      VERSION   SIZE     READ ONLY   TRANSPORT   ROTATIONAL   WWID   MODEL   SERIAL
          runtime     Disk   loop0   1         75 MB    true
          runtime     Disk   sr0     1         310 MB   true        ata         ...
          runtime     Disk   vda     1         11 GB    false       virtio      true
          runtime     Disk   vdb     1         6.4 GB   false       virtio      true
   ```

   - `sr0` is the CD-ROM drive with the ISO. `loop0` is the Talos root file system (SquashFS) in RAM.
   - `vda` is empty. This is the install disk.

3. Try to read a file. The maintenance API refuses it:

   ```bash
   talosctl -n 10.5.5.3 read /etc/os-release --insecure
   ```

   The command fails with an error that contains `PermissionDenied` (or `not authorized`).

### Step 3: Make the secrets and the configuration

```bash
talosctl gen secrets -o build/secrets.yaml
talosctl gen config install https://10.5.5.2:6443 --with-secrets build/secrets.yaml \
  --install-disk /dev/vda --with-docs=false --with-examples=false --output build/
ls build/
```

Expected output of `ls`: `controlplane.yaml  provisioner  secrets.yaml  state  talosconfig  worker.yaml`.

Show the install settings:

```bash
yq 'select(.kind == "UnattendedInstallConfig")' build/controlplane.yaml
```

Expected output:

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.4
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/vda"
  wipe: false
```

- The installer image comes from the Image Factory. The long ID is the *schematic* without customizations
  (stage 06 makes a different one).
- `diskSelector.match` is a CEL expression. You can select a disk by size, model or serial number, for
  example `disk.size > 8u * GB && !disk.rotational`.

### Step 4: Set the endpoint and the node

The new `talosconfig` (in `build/`, the value of `TALOSCONFIG`) has no endpoint:

```bash
talosctl config info
talosctl config endpoint 10.5.5.2
talosctl config node 10.5.5.2
talosctl config info
```

### Step 5: Apply the configuration

1. Apply the control plane configuration with a fixed host name:

   ```bash
   talosctl apply-config --insecure -n 10.5.5.2 -f build/controlplane.yaml -p @node-patches/controlplane-1.yaml
   ```

   The flag `-p` patches the file before `talosctl` sends it. The file on the disk does not change.

2. Apply the worker configuration:

   ```bash
   talosctl apply-config --insecure -n 10.5.5.3 -f build/worker.yaml -p @node-patches/worker-1.yaml
   ```

3. Watch the install on the console of the control plane node:

   ```bash
   tail -f build/state/install/install-controlplane-1.log
   ```

   Expected lines (example, part):

   ```
   [talos] task install (1/1): starting
   [talos] pulling "factory.talos.dev/metal-installer/3765...:v1.14.4"
   [talos] created EFI (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) size 1073741824 bytes
   [talos] created META (...) size 1048576 bytes
   [talos] created STATE (...) size 104857600 bytes
   [talos] created EPHEMERAL (...) size ...
   [talos] installation of v1.14.4 complete
   [talos] rebooting
   ```

   Stop `tail` with `Ctrl+C` when the node shows `etcd is waiting to join the cluster` or
   `service[etcd](Preparing)`.

### Step 6: Bootstrap etcd

```bash
talosctl bootstrap
```

The command has no output if it succeeds. Watch etcd and the control plane start:

```bash
talosctl service etcd
talosctl get staticpodstatus --watch      # stop with Ctrl+C when 3 static pods show
```

### Step 7: Get the kubeconfig and check the cluster

```bash
talosctl kubeconfig "$KUBECONFIG"
mise run check
```

Expected output at the end (example):

```
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE          KERNEL-VERSION   CONTAINER-RUNTIME
install-controlplane-1   Ready    control-plane   3m    v1.37.1   10.5.5.2      <none>        Talos (v1.14.4)   6.18.x-talos     containerd://2.x
install-worker-1         Ready    <none>          3m    v1.37.1   10.5.5.3      <none>        Talos (v1.14.4)   6.18.x-talos     containerd://2.x
```

> **Shortcut:** `mise run install` does steps 3 to 7. Use it if you want to go directly to the experiments.

## Experiments

Do the experiments after the procedure, in the sequence below.

### Experiment 1: Examine the partitions and volumes

1. Show the partitions on the system disk:

   ```bash
   talosctl get discoveredvolumes
   ```

   Expected output (example, part):

   ```
   NODE       NAMESPACE   TYPE               ID     VERSION   TYPE        SIZE     DISCOVERED   LABEL       PARTITIONLABEL
   10.5.5.2   runtime     DiscoveredVolume   vda    1         disk        11 GB    gpt
   10.5.5.2   runtime     DiscoveredVolume   vda1   1         partition   1.1 GB   vfat         EFI         EFI
   10.5.5.2   runtime     DiscoveredVolume   vda2   1         partition   1.0 MB   talosmeta                META
   10.5.5.2   runtime     DiscoveredVolume   vda3   1         partition   105 MB   xfs          STATE       STATE
   10.5.5.2   runtime     DiscoveredVolume   vda4   1         partition   9.5 GB   xfs          EPHEMERAL   EPHEMERAL
   ```

2. Show the volumes that Talos manages, and their mount points:

   ```bash
   talosctl get volumestatuses
   talosctl get mountstatuses
   ```

   `STATE` is mounted at `/system/state`. `EPHEMERAL` is mounted at `/var`.

3. Show the configuration file in STATE:

   ```bash
   talosctl list /system/state
   ```

   Expected output: one file, `config.yaml`.

4. Compare with the Docker stages: in Docker, `/system/state` and `/var` are Docker volumes, and there is no
   `EFI` or `META` partition.

### Experiment 2: Compare your configuration with the configuration of the provisioner

The `up` task kept the configuration that `talosctl cluster create` would apply. List the document kinds of
both control plane files:

```bash
diff <(yq -N '.kind // "(v1alpha1)"' build/controlplane.yaml) \
     <(yq -N '.kind // "(v1alpha1)"' build/provisioner/controlplane.yaml)
```

Expected differences (example): the provisioner adds `LinkAliasConfig` (the name `net0` for the virtio
network link) and `DHCPv4Config` for `net0`. Your configuration works without them: without a network
configuration, Talos uses DHCP on the first link.

Compare the Kubernetes endpoints:

```bash
yq 'select(.kind == "KubeClusterConfig") | .endpoint' build/controlplane.yaml build/provisioner/controlplane.yaml
```

Expected output: `https://10.5.5.2:6443` (your configuration, one control plane node) and
`https://10.5.5.1:6443` (the load balancer of the provisioner, in front of all control plane nodes).

### Experiment 3: Reset the worker to maintenance mode

1. Reset the worker. `--graceful` (the default) cordons and drains the node first. `--reboot` starts it again
   after the wipe:

   ```bash
   talosctl -n 10.5.5.3 reset --reboot
   ```

   The default `--wipe-mode all` deletes the complete system disk. The next boot uses the ISO again.

2. Show the result:

   ```bash
   kubectl get nodes                                   # install-worker-1 becomes NotReady
   talosctl -n 10.5.5.3 version --insecure             # the node is in maintenance mode again
   talosctl -n 10.5.5.3 get disks --insecure
   ```

3. Install the worker again:

   ```bash
   talosctl apply-config --insecure -n 10.5.5.3 -f build/worker.yaml -p @node-patches/worker-1.yaml
   kubectl get nodes --watch                           # stop with Ctrl+C when install-worker-1 is Ready
   ```

   The node gets the same name and joins again. Kubernetes uses the existing Node object.

### Experiment 4: Reset only the EPHEMERAL partition

1. Start a pod on the worker and pull an image:

   ```bash
   kubectl run web --image=nginx:1.29-alpine --overrides='{"spec":{"nodeName":"install-worker-1"}}'
   kubectl wait --for=condition=Ready pod/web
   talosctl -n 10.5.5.3 image list --namespace cri | grep nginx
   ```

2. Wipe only EPHEMERAL and reboot:

   ```bash
   talosctl -n 10.5.5.3 reset --system-labels-to-wipe EPHEMERAL --reboot
   ```

3. When the node is `Ready` again, examine the result:

   ```bash
   kubectl get nodes
   talosctl -n 10.5.5.3 image list --namespace cri | grep nginx || echo "image is gone"
   talosctl -n 10.5.5.3 get machineconfig
   ```

   - The configuration is still there (STATE). The node did not go to maintenance mode.
   - The container images are gone (EPHEMERAL). Kubernetes starts the pod again and pulls the image again.

4. Delete the pod:

   ```bash
   kubectl delete pod web
   ```

### Experiment 5: The maintenance API is closed after the install

```bash
talosctl -n 10.5.5.3 apply-config --insecure -f build/worker.yaml
```

The command fails with a TLS or authentication error. An installed node accepts only clients with a
certificate from its Talos CA. To change the configuration of an installed node, use `apply-config`
without `--insecure` (with the `talosconfig`), as in stage 02.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `error: /dev/kvm not found`. | KVM is not available. | Enable virtualization in the firmware. In a VM, enable nested virtualization. Add your user to the group `kvm`. |
| `cluster create` fails with a CNI or iptables error. | The CNI bundle download failed, or `iptables` is missing. | Delete `~/.talos/cni` and try again. Install `iptables`. |
| `cluster create` fails with an OVMF error. | No UEFI firmware. | Install `ovmf` (Debian, Ubuntu) or `edk2-ovmf` (Fedora). |
| `apply-config --insecure` fails with `no route to host`. | The VM has not booted yet, or it has no address because firewalld rejects DHCP on the bridge. | `tail build/state/install/install-controlplane-1.log`. Wait for the maintenance mode message. If the log shows `DHCP request/renew failed`, put the bridge into the zone `trusted` (see the host requirements in the top-level README). |
| The install stops at the image pull. The VM log shows `i/o timeout` for outgoing TCP connections. | The host does not forward the traffic of the VM. Docker sets the policy of the chain `FORWARD` to `DROP`. | `sudo iptables -S DOCKER-USER` must show the two rules for `talos+` (see the host requirements in the top-level README). Check `net.ipv4.ip_forward=1`. |
| `bootstrap` fails with `etcd data directory is not empty`. | The node has etcd data from an earlier bootstrap. | Do not bootstrap again. If you want a new cluster, `mise run down` and start again. |
| `talosctl` commands fail with `certificate signed by unknown authority`. | `TALOSCONFIG` points to the configuration of the provisioner, or you made new secrets after the install. | Use `build/talosconfig` from step 3. Do not run `gen secrets` again for installed nodes. |
| Files in `build/` belong to root. | `talosctl` ran with `sudo`. | `sudo chown -R "$(id -u):$(id -g)" build`. |

## Clean up

```bash
mise run down
```

The task stops the VMs and deletes the bridge, the disks and the state. The ISO stays in the cache in
`~/.talos` for the next stage.

## References

- QEMU provisioner: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/qemu
- Getting started (manual install): https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started
- Maintenance mode: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/insecure
- Unattended install: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/unattended-install
- `UnattendedInstallConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/runtime/unattendedinstallconfig
- Disk layout: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/layout
- Reset a machine: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/resetting-a-machine
