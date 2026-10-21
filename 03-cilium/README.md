# 03 – Cilium: CNI "none" and no kube-proxy

## Purpose

Talos installs Flannel and kube-proxy by default. This stage removes both and installs Cilium as the CNI
plugin with kube-proxy replacement. The Cilium functions themselves are the subject of the
[cilium-labs](https://github.com/dennisklein/cilium-labs) repository. This stage is about what is special on
Talos.

When you complete this stage, you know:

- Which configuration documents disable Flannel and kube-proxy.
- Why a Talos cluster without a CNI waits in the boot sequence, and how to install the CNI in this window.
- What KubePrism is and why Cilium uses `localhost:7445` as the API server address.
- Which Cilium Helm values are necessary on Talos, and why.
- The four ways to install a CNI on Talos.

## Concepts

### Default CNI and kube-proxy are documents

Two documents of the control plane configuration make the default network:

| Document | Default | To disable |
|----------|---------|------------|
| `KubeFlannelCNIConfig` | Flannel, VXLAN on UDP 4789 | Delete the document (`$patch: delete`). |
| `KubeProxyConfig` | kube-proxy in nftables mode | `enabled: false`. |

The file `patches/controlplane/no-flannel-no-kube-proxy.yaml` does both. These documents exist only in the
control plane configuration. Thus, the `up` task gives the patch with `--config-patch-controlplanes`.

### The boot sequence waits for a CNI

Without a CNI, the kubelet reports `NotReady`. Talos and `talosctl cluster create` wait until all nodes are
`Ready`. The API server is up in this time. Thus, you can install the CNI while the cluster waits:

```
 time ----------------------------------------------------------------------------------->

 talosctl cluster create (background)
   containers --> config --> bootstrap --> etcd, API server up --> wait for Ready nodes ...... done
                                                 |                                     ^
 up task (foreground)                            |                                     |
   wait for talosctl kubeconfig ----------------+                                     |
   cilium install (values.yaml) ---> Cilium agents start ---> nodes Ready -------------+
```

The `up` task gets a temporary kubeconfig with `talosctl kubeconfig`. Its server is the in-cluster endpoint
`https://10.5.3.2:6443`. On Linux, the host reaches this address on the Docker bridge. When the create command
ends, it writes the final kubeconfig (`https://127.0.0.1:<port>`) to `build/kubeconfig`.

### KubePrism

KubePrism is a TCP load balancer on each Talos node, on `localhost:7445`. It sends connections to all
healthy API servers. The list of API servers comes from the discovery service and from the Kubernetes
`kubernetes` Service endpoints.

```
 any node
 +--------------------------------------------------------------+
 |  cilium-agent ---> localhost:7445 (KubePrism) --+--> 10.5.3.2:6443 (API server)
 |  kubelet     ---> localhost:7445             --+--> (other control plane nodes, if any)
 +--------------------------------------------------------------+
```

Without kube-proxy, a pod cannot use the `kubernetes` Service (10.96.0.1) before Cilium runs, because Cilium
implements Services. Cilium needs the API server to start. KubePrism breaks this loop: Cilium connects to
`localhost:7445`, which works without Services and with any number of control plane nodes.

### Cilium values for Talos

| Value | Why |
|-------|-----|
| `ipam.mode: kubernetes` | Talos gives each node a pod CIDR (`KubeNetworkConfig`). |
| `kubeProxyReplacement: true` | kube-proxy is disabled. |
| `k8sServiceHost: localhost`, `k8sServicePort: 7445` | KubePrism (see above). |
| `cgroup.autoMount.enabled: false`, `cgroup.hostRoot: /sys/fs/cgroup` | Talos mounts cgroup v2. Cilium must not mount it again. |
| `securityContext.capabilities.*` | The chart default has `SYS_MODULE`. Talos does not let pods load kernel modules. The lists are the defaults without `SYS_MODULE`. |

### Four ways to install a CNI on Talos

| Method | How | Note |
|--------|-----|------|
| CLI in the boot window | `cilium install` or `helm install` while the cluster waits | This stage. Simple, not declarative. |
| Inline manifest | `helm template` output in a `KubeInlineManifestConfig` document of the control plane | Declarative. Talos applies it at bootstrap and creates missing objects. It never updates or deletes them. |
| External manifest | `KubeExternalManifestConfig` with a URL | The manifest has secret material. Host it only on a private server. |
| Omni manifest sync | Omni applies the manifest | Only with Omni. |

The Docker provisioner gives the machine configuration to a node in one environment variable. Linux limits
one environment string to 128 KiB. A rendered Cilium manifest in a `KubeInlineManifestConfig` can make the
configuration too large for this limit. Thus, this stage uses the CLI method.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `cilium` |
| Provisioner | Docker |
| Nodes | `cilium-controlplane-1` (10.5.3.2), `cilium-worker-1` (10.5.3.3), `cilium-worker-2` (10.5.3.4) |
| Docker network | `cilium`, `10.5.3.0/24` |
| Pod subnet | `10.244.0.0/16`, one `/24` per node (Cilium IPAM `kubernetes`) |
| CNI | Cilium (latest stable), VXLAN tunnel, kube-proxy replacement |
| kube-proxy, Flannel | no |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=cilium`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `check` and `down`. |
| `mise-tasks/up` | Creates the cluster in the background and installs Cilium in the boot window. |
| `patches/controlplane/no-flannel-no-kube-proxy.yaml` | Deletes `KubeFlannelCNIConfig`, disables kube-proxy. |
| `values.yaml` | The Cilium Helm values for Talos. |

## Procedure

Do the steps in the stage folder (`03-cilium/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 //:preflight          docker info, Talos version
       |
 talos_up_docker &     talosctl cluster create docker --name cilium --workers 2
       |                 --config-patch-controlplanes @patches/controlplane/no-flannel-no-kube-proxy.yaml
       |
 talosctl kubeconfig   repeat until the API server gives a kubeconfig (build/kubeconfig.boot)
       |
 cilium_up             cilium install --version <latest stable> --values values.yaml
       |
 wait                  cluster create ends when all nodes are Ready
       |
 mise run check        cilium status --wait; nodes; daemonsets
```

While Cilium is not running, the create command shows lines like this (example):

```
waiting for all k8s nodes to report ready: some nodes are not ready: [cilium-controlplane-1 cilium-worker-1 cilium-worker-2]
```

Expected output at the end (example):

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled
...
NAME           DESIRED   CURRENT   READY   ...
cilium         3         3         3       ...
cilium-envoy   3         3         3       ...
```

The list of daemonsets has no `kube-proxy` and no `kube-flannel`.

### Step 2: Examine the configuration documents

```bash
talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' | yq 'select(.kind == "KubeProxyConfig")'
talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' | yq -N '.kind // "(v1alpha1)"' | grep -c Flannel
```

The `KubeProxyConfig` has `enabled: false`. The count of Flannel documents is `0`.

### Step 3: Examine KubePrism

```bash
talosctl -n 10.5.3.3 get kubeprismstatuses
talosctl -n 10.5.3.3 get kubeprismendpoints -o yaml
```

Expected output of the first command (example):

```
NODE       NAMESPACE   TYPE                ID              VERSION   HOST             HEALTHY
10.5.3.3   k8s         KubePrismStatus     k8s-cluster     1         localhost:7445   true
```

The endpoints resource lists the API servers that KubePrism uses (here `10.5.3.2:6443`).

### Step 4: Examine Cilium

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Kubernetes:'
cilium config view | grep -E '^(ipam|kube-proxy-replacement|k8s-service-host|k8s-service-port|routing-mode) '
```

Expected output (example):

```
Kubernetes:              Ok   1.37 (v1.37.1) [linux/amd64]
KubeProxyReplacement:    True   [eth0   10.5.3.3 ...]
Routing:                 Network: Tunnel [vxlan]   Host: BPF
...
ipam                       kubernetes
k8s-service-host           localhost
k8s-service-port           7445
kube-proxy-replacement     true
routing-mode               tunnel
```

### Step 5: Do the connectivity test

```bash
cilium connectivity test
```

The test takes some minutes. Expected output at the end:

```
✅ [cilium-test-1] All NN tests (MMM actions) successful, K tests skipped, 0 scenarios skipped.
```

If the host has no direct internet access, skip the tests that go to the internet:

```bash
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

The test namespace `cilium-test-1` has Pod Security `enforce: privileged`, set by the test. The Talos default
for other namespaces is `baseline` (`KubeAdmissionControlConfig`).

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: A Service without kube-proxy

1. Make a Deployment and a Service:

   ```bash
   kubectl create deployment web --image=nginx:1.29-alpine --replicas=2
   kubectl expose deployment web --port=80
   kubectl rollout status deployment web
   ```

2. Show the Service in the Cilium load balancer map. This map replaces the kube-proxy rules:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep -A2 "$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')"
   ```

3. Show that no node has kube-proxy rules. Talos keeps its own nftables chains as resources:

   ```bash
   talosctl -n 10.5.3.3 get nftableschains
   ```

   The list has only the Talos chains (for example the ingress firewall chain, if configured). There is no
   `kube-proxy` table.

4. Delete the objects:

   ```bash
   kubectl delete service web; kubectl delete deployment web
   ```

### Experiment 2: KubePrism keeps working when the Service is not reachable

1. Show the API server address that the Cilium agent uses:

   ```bash
   kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.k8s-service-host}:{.data.k8s-service-port}{"\n"}'
   ```

   Expected output: `localhost:7445`.

2. Restart the Cilium agents. While the agents restart, no node implements the `kubernetes` Service. The agents
   still connect, because they use KubePrism:

   ```bash
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Show the KubePrism connection in the log of an agent:

   ```bash
   kubectl -n kube-system logs ds/cilium | grep -m3 -i 'localhost:7445'
   ```

### Experiment 3: Capabilities of the agent

1. Show the capabilities of the `cilium-agent` container:

   ```bash
   kubectl -n kube-system get ds cilium \
     -o jsonpath='{.spec.template.spec.containers[?(@.name=="cilium-agent")].securityContext.capabilities.add}{"\n"}'
   ```

   The list has no `SYS_MODULE`.

2. Show the kernel modules that Talos loaded. Talos loads modules for its own functions (and the ones in
   `KernelModuleConfig`). Pods cannot load modules:

   ```bash
   talosctl -n 10.5.3.3 get kernelmodulestatuses | head -20
   ```

   In Docker, the nodes use the kernel of the host. Thus, the list shows the modules of the host.

### Experiment 4: Compare with the inline manifest method

This experiment does not change the cluster. It shows the size of an inline manifest.

1. Render the Cilium manifest with the values of this stage:

   ```bash
   helm repo add cilium https://helm.cilium.io/ && helm repo update cilium
   helm template cilium cilium/cilium --version "$(cilium version --client | sed -n 's/^cilium image (stable): v//p')" \
     --namespace kube-system --values values.yaml > build/cilium.yaml
   ls -l build/cilium.yaml
   ```

2. Put it into a `KubeInlineManifestConfig` document and compute the size of the base64 string:

   ```bash
   { printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: cilium\nmanifest: |\n'
     sed 's/^/  /' build/cilium.yaml; } > build/cilium-inline.yaml
   talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' | cat - <(echo ---) build/cilium-inline.yaml \
     | base64 -w0 | wc -c
   ```

   If the number is more than 131072 (128 KiB), the Docker provisioner cannot give this configuration to a node.
   On QEMU and on real machines, there is no such limit, and the inline manifest is the recommended
   production method.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| The `up` task waits a long time at `talosctl kubeconfig`. | The control plane is not up yet, or the bootstrap failed. | In a second terminal: `talosctl -n 10.5.3.2 dmesg -f` and `talosctl -n 10.5.3.2 services`. |
| `cluster create` fails after 20 minutes, `nodes are not ready`. | Cilium did not start (for example, no image pull). | `kubectl --kubeconfig build/kubeconfig.boot -n kube-system get pods`, then the agent logs. |
| The agents fail with `operation not permitted` for a module. | A value list has `SYS_MODULE`, or a Cilium function needs a module that the host kernel does not have. | Use `values.yaml` as it is. In Docker, the host kernel must have the module. |
| CoreDNS does not answer when `bpf.masquerade: true`. | Known issue with the Talos host DNS forwarding (`forwardKubeDNSToHost`). | Do not set `bpf.masquerade`, or set `forwardKubeDNSToHost: false` in `ResolverConfig.hostDNS`. |
| The connectivity test fails for *world* tests. | The host has no direct internet access. | Skip the world tests (see step 5). |

## Clean up

```bash
mise run down
```

## References

- Deploy Cilium on Talos: https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- KubePrism: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism
- `KubeFlannelCNIConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeflannelcniconfig
- `KubeProxyConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeproxyconfig
- `KubeInlineManifestConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeinlinemanifestconfig
- Cilium kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- cilium-labs, stage 02 (kube-proxy replacement): https://github.com/dennisklein/cilium-labs/blob/master/02-kpr-hubble-policy/README.md
