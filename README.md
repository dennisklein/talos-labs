# Talos Linux lab ladder

## Purpose

This repository is a series of labs ("stages") for Talos Linux 1.14 and later. Each stage is a folder with a
small Talos cluster and a topic. Stages 01 to 03 run Talos in Docker containers (fast, no disks, no boot).
Stages 04 to 09 run Talos in QEMU virtual machines (KubeSpan, install, upgrade, disks, Secure Boot). Do the
stages in sequence. Each stage README has the concepts, ASCII diagrams, a step-by-step procedure with expected
output, experiments and troubleshooting.

## The stages

```
 Docker                                   QEMU (KVM, sudo)
 01 basic      API, talosctl, resources
  |
 02 config     multi-document config,
  |            patches, apply modes
  +-- 03 cilium no Flannel, no kube-proxy, Cilium, KubePrism
  |
  +------------------------------------> 04 kubespan WireGuard mesh, discovery, peer down
  |
  +------------------------------------> 05 install  maintenance mode, gen config, bootstrap, reset
                                          |
                                         06 upgrade  Image Factory, extensions, A/B, rollback, upgrade-k8s
                                          |
                                         07 ha       3 control planes, VIP, etcd, disaster recovery
                                          |
                                         08 storage  volumes, extra disks, LUKS2, local PV
                                          |
                                         09 secure   Secure Boot, TPM, RBAC, ingress firewall
```

| Stage | Cluster | Subnet | Nodes | Adds |
|-------|---------|--------|-------|------|
| [01-basic](01-basic/README.md) | `basic` | 10.5.1.0/24 | 1 CP + 2 W, Docker | Talos API, endpoints and nodes, services, resources |
| [02-machine-config](02-machine-config/README.md) | `config` | 10.5.2.0/24 | 1 CP + 1 W, Docker | Multi-document configuration, patches, apply modes, `try` |
| [03-cilium](03-cilium/README.md) | `cilium` | 10.5.3.0/24 | 1 CP + 2 W, Docker | Cilium without Flannel and kube-proxy, KubePrism |
| [04-kubespan](04-kubespan/README.md) | `kubespan` | 10.5.4.0/24 | 1 CP + 2 W, QEMU | Discovery service, KubeSpan WireGuard mesh |
| [05-install](05-install/README.md) | `install` | 10.5.5.0/24 | 1 CP + 1 W, QEMU | Maintenance mode, manual install, bootstrap, partitions, reset |
| [06-upgrade](06-upgrade/README.md) | `upgrade` | 10.5.6.0/24 | 1 CP + 1 W, QEMU | Schematic, system extension, Talos and Kubernetes upgrade, rollback |
| [07-ha](07-ha/README.md) | `ha` | 10.5.7.0/24 | 3 CP + 1 W, QEMU | etcd quorum, Layer 2 VIP, etcd operations, recovery from a snapshot |
| [08-storage](08-storage/README.md) | `storage` | 10.5.8.0/24 | 1 CP + 2 W, QEMU | User and raw volumes, EPHEMERAL size, LUKS2, local PersistentVolume |
| [09-secure](09-secure/README.md) | `secure` | 10.5.9.0/24 | 1 CP + 1 W, QEMU | Secure Boot, TPM disk encryption, API roles, ingress firewall |

Each stage has its own cluster name and subnet. Thus, you can keep a stage and start a different stage. Each
cluster uses CPU and memory (QEMU: 2 GiB per VM). On a small host, do `mise run down` before you start the
next stage.

## How a stage works

```
 host
 +--------------------------------------------------------------------------------------+
 |  mise     tools (talosctl, kubectl, helm, cilium-cli, jq, yq) and env per stage       |
 |   |                                                                                  |
 |   +-- mise run up --> talosctl cluster create docker   (stages 01-03)                |
 |   |                   talosctl cluster create qemu     (stages 04-09, with sudo)     |
 |   |                   --config-patch @patches/...      (if the stage has patches)    |
 |   |               --> mise run check                   (health and stage probes)     |
 |   |                                                                                  |
 |   +-- <stage>/build/  talosconfig, kubeconfig, state of the provisioner, your files   |
 |                                                                                      |
 |  Docker: network <cluster>, one container per node      QEMU: bridge, DHCP, LB on .1, |
 |  10.5.N.2 = control plane, .3 and up = workers           one VM per node, same IPs   |
 +--------------------------------------------------------------------------------------+
```

Each stage folder has these tasks:

| Task | What it does |
|------|--------------|
| `up` | Makes the cluster with the patches of the stage, then runs `check`. Stage 05 stops in maintenance mode. |
| `check` | Runs `talosctl health` and the probes of the stage again. |
| `down` | Destroys the cluster (containers or VMs, network, state). |

Stage 05 also has `install` (steps 3 to 7 of its procedure in one command).

The `patches/` folder of a stage is applied when the cluster is made: `patches/*.yaml` to all nodes,
`patches/controlplane/*.yaml` and `patches/worker/*.yaml` to one node type. The `examples/` folder has
documents for the procedure and the experiments; you apply them by hand.

## Quick start

1. Install [mise](https://mise.jdx.dev/) and Docker. For stages 04 to 09, also install the QEMU host
   requirements (see below). These come from the operating system, not from mise.
2. In the repository root, trust the configuration and install the tools:

   ```bash
   mise trust -a && mise install
   ```

3. Activate mise in the shell. Then mise loads the `[env]` of a stage when you go into its folder
   (`TALOSCONFIG`, `KUBECONFIG`, ...):

   ```bash
   eval "$(mise activate bash)"
   ```

4. Start the first stage:

   ```bash
   cd 01-basic && mise run up
   ```

   From the repository root, you can also do `mise run //01-basic:up`.

5. Do the procedure in the README of the stage.
6. Delete the stage:

   ```bash
   mise run down
   ```

Other useful commands:

- `mise tasks ls --all` shows the tasks of all stages.
- `mise run down-all` deletes all stages, one after the other.

## Host requirements

### All stages

| Item | Note |
|------|------|
| Linux host, x86_64 | The labs are tested on Linux. |
| Docker | Stages 01 to 03. The user must be in the group `docker`. |
| Internet access | Images from `ghcr.io`, `factory.talos.dev`, `registry.k8s.io`; discovery at `discovery.talos.dev`. |
| `br_netfilter` kernel module | `sudo modprobe br_netfilter`. Without it, the Flannel pods fail with `Failed to check br_netfilter`, and `cluster create docker` waits for `Ready` nodes until its timeout. |

### QEMU stages (04 to 09)

| Item | Debian, Ubuntu | Fedora | Note |
|------|----------------|--------|------|
| KVM | `/dev/kvm` | `/dev/kvm` | Enable virtualization in the firmware. In a VM, enable nested virtualization. |
| QEMU | `qemu-system-x86 qemu-kvm` | `qemu-kvm` | `qemu-system-x86_64` must be in `PATH`. |
| UEFI firmware | `ovmf` | `edk2-ovmf`, `qemu-img` | Stage 09 needs the 4 MB Secure Boot build with TPM support (`OVMF_CODE_4M.secboot.fd`). On Fedora, the `up` task of stage 09 makes it from the qcow2 file with `qemu-img`, in `/usr/share/ovmf`. |
| Software TPM | `swtpm swtpm-tools` | `swtpm swtpm-tools` | Stage 09. |
| iptables | `iptables` | `iptables` | The CNI plugins of the provisioner use it. |
| firewalld | | | If firewalld is active, it rejects DHCP from the VMs on the new bridge. The `up` tasks put the bridge into the zone `trusted` (runtime only, until the next reload). |
| Docker | | | If Docker is installed, it sets the policy of the iptables chain `FORWARD` to `DROP`. The VMs then have no internet access. The `up` tasks add two `ACCEPT` rules for the bridges `talos*` to the chain `DOCKER-USER` (until the next reboot). |
| sudo | | | `talosctl cluster create qemu` runs as root. The `up` and `down` tasks ask for the `sudo` password. |
| `socat`, `nc`, `openssl`, `curl`, `tcpdump` | `socat netcat-openbsd openssl curl tcpdump` | `socat nmap-ncat openssl curl tcpdump` | Experiments in stages 04, 06, 07 and 09. |
| Memory | | | 2 GiB per VM. Stage 07 needs 8 GiB free. |

`talosctl` downloads the CNI plugins for the VMs to `~/.talos/cni` and caches the boot images in `~/.talos`.
Because it runs as root, these files belong to root.

## Configuration

### mise

The root `mise.toml` is the single source of truth for the tools and the shared environment:

- `[tools]`: `talosctl`, `kubectl`, `helm`, `cilium-cli`, `jq`, `yq`. All tools use `latest`. The lock file
  `mise.lock` keeps the tested versions (see [Tool versions](#tool-versions)).
- `[env]`: `LAB_ROOT`. The stage tasks use it to find the shared shell functions in `lib/lab.sh`.
- Hidden tasks `preflight` (Docker, Talos version) and `preflight-qemu` (KVM, QEMU, Talos version, `sudo`).

Each stage `mise.toml` sets `CLUSTER`, `SUBNET`, `TALOSCONFIG` (`<stage>/build/talosconfig`) and
`KUBECONFIG` (`<stage>/build/kubeconfig`). With `mise activate`, `talosctl` and `kubectl` in a stage folder
use the cluster of that stage. You do not need `--context`.

Without `mise activate`, use `mise x -- talosctl ...` in the stage folder.

### Tool versions

`mise.toml` requests `latest` for each tool. `mise.lock` records the versions that the labs are tested with,
with their download URLs and checksums. `mise install` installs the locked versions, not the newest ones.
The expected outputs in the READMEs come from these versions.

To move the labs to new releases:

```bash
mise lock --bump --platform linux-x64   # resolve "latest" again and write mise.lock
mise install
```

Then do the stages again, correct the READMEs where the outputs changed, and commit `mise.lock` with the
corrections. Without `--bump`, `mise lock` keeps the locked versions and refreshes only their URLs and
checksums.

### Talos version

By default, the labs use the Talos version of `talosctl`, which is the version in `mise.lock`. A new Talos
release goes into the labs with the next `mise lock --bump`. The function `talos_version` in
`lib/lab.sh` reads the version from `talosctl version --client`, and the stages use it for:

- the node image in Docker: `ghcr.io/siderolabs/talos:<version>`,
- the boot ISO and the installer image in QEMU: `factory.talos.dev/.../<version>`.

The preflight tasks refuse versions before 1.14. The labs use the multi-document configuration of 1.14.

To pin the Talos version, set `TALOS_VERSION`, and pin `talosctl` to the same version. A `talosctl` of a
different minor release can generate a configuration that the nodes do not know.

- For all stages, for all users: change the root `mise.toml`.

  ```toml
  [tools]
  talosctl = "1.14.3"

  [env]
  TALOS_VERSION = "1.14.3"
  ```

- For all stages, only on your computer: put the same blocks in `mise.local.toml` in the repository root.
  git ignores this file. Then run `mise install`.
- For one run (same minor release as `talosctl` only): `TALOS_VERSION=1.14.3 mise run up`.

Show the active versions:

```bash
talosctl version --client
mise ls talosctl
```

Stage 06 starts one patch release behind (`talos_previous_version`) and upgrades to the labs version
(`talos_version`).

### Kubernetes version

The Kubernetes version is the default of `talosctl` (`talosctl cluster create qemu --help`, flag
`--kubernetes-version`). Stage 06 starts with the latest patch release of the minor release before it, to
show `talosctl upgrade-k8s`.

### Cilium version

Stage 03 installs Cilium with `cilium install`. As in the
[cilium-labs](https://github.com/dennisklein/cilium-labs/blob/master/README.md#cilium-version) repository,
`cilium_up` uses the latest stable Cilium release, and `CILIUM_VERSION` pins it.

## Recommendations

- **inotify limits.** Many Talos containers need more inotify watches and instances than the default. Set them
  on the host:

  ```bash
  sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
  ```

- **Proxy.** The nodes do not use the proxy of the host. Talos can use a proxy with `EnvironmentConfig`, but
  the labs do not configure one. If the host needs a proxy for the internet, the image pulls and the discovery
  service do not work.
- **One QEMU stage at a time.** The QEMU stages use 4 to 8 GiB of memory. Do `mise run down` before the next
  stage.

## Notes

- `talosctl cluster create docker` cannot upgrade, reset to maintenance mode or use disks. These topics are
  in the QEMU stages.
- The QEMU provisioner runs the VMs, DHCP, DNS and the load balancer as background processes. `mise run down`
  stops them. If a stage folder is deleted without `down`, see the cleanup section of the QEMU documentation.
- The files in `build/` are generated. git ignores them. In the QEMU stages, the tasks give `talosconfig` and
  `kubeconfig` back to your user; the state folder `build/state` belongs to root.
- The talosconfig endpoints are the node addresses (Docker: the forwarded port on `127.0.0.1`). Do not use a
  VIP as endpoint (see stage 07).

## Documentation

- Talos 1.14: https://docs.siderolabs.com/talos/v1.14/overview/what-is-talos
- Configuration reference: https://docs.siderolabs.com/talos/v1.14/reference/configuration/overview
- `talosctl` reference: https://docs.siderolabs.com/talos/v1.14/reference/cli
- Docker provisioner: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/docker
- QEMU provisioner: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/qemu
- Image Factory: https://factory.talos.dev/
- Version note: the documentation URLs contain the minor version (`v1.14`). For a later Talos release,
  replace it in the URL.
