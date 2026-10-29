# 03 – Cilium: CNI "none" and no kube-proxy

## Purpose

Talos installs Flannel and kube-proxy by default. This stage removes both and installs Cilium as the CNI
plugin with kube-proxy replacement. The Cilium functions themselves are the subject of the
[cilium-labs](https://github.com/dennisklein/cilium-labs) repository. This stage is about what is special on
Talos.

When you complete this stage, you know:

- Which configuration documents disable Flannel and kube-proxy.
- Why `talosctl cluster create` skips the `Ready` checks when the CNI is `none`, and why you install the CNI
  after it.
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

### A cluster without a CNI

Without a CNI, the kubelet reports `NotReady`. `talosctl cluster create` and `talosctl health` read the
resource `BootstrapManifestsConfig`. If its CNI is `none`, they skip the checks for `Ready` nodes, kube-proxy
and CoreDNS (`SKIP`). Thus, the create command ends with `NotReady` nodes, and you install the CNI after it:

```
 time ----------------------------------------------------------------------------------->

 talosctl cluster create
   containers --> config --> bootstrap --> etcd, API server up --> checks (Ready: SKIP) --> done
                                                                                            |
 cilium install (values.yaml) <-------------------------------------------------------------+
   Cilium agents start ---> CoreDNS starts ---> nodes Ready
```

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
| CLI after the create | `cilium install` or `helm install` | This stage. Simple, not declarative. |
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
| `mise-tasks/up` | Creates the cluster, then installs Cilium. |
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
 talos_up_docker       talosctl cluster create docker --name cilium --workers 2
       |                 --config-patch-controlplanes @patches/controlplane/no-flannel-no-kube-proxy.yaml
       |
 cilium_up             cilium install --version <latest stable> --values values.yaml
       |
 mise run check        cilium status --wait; nodes; daemonsets
```

At the end, the create command shows these lines:

```
waiting for all k8s nodes to report ready: SKIP
waiting for kube-proxy to report ready: SKIP
waiting for coredns to report ready: SKIP
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

Some test pods use host ports and extra capabilities. The Talos default Pod Security level is `baseline`
(`KubeAdmissionControlConfig`). This level refuses host ports. The test does not label its namespaces. Thus,
give the label `enforce: privileged` to all test namespaces:

```bash
cilium connectivity test --namespace-labels pod-security.kubernetes.io/enforce=privileged
```

The test takes approximately 10 minutes. Expected output at the end (example):

```
✅ [cilium-test-1] All 55 tests (176 actions) successful, 80 tests skipped, 9 scenarios skipped.
```

The test skips the tests that can change the nodes, and the tests that need more nodes or other Cilium
functions.

The lines `Warning: would violate PodSecurity "restricted:latest"` are normal. The Talos default `warn` level
is `restricted`, and the label changes only `enforce`.

If the host has no direct internet access, also skip the tests that go to the internet:

```bash
cilium connectivity test --namespace-labels pod-security.kubernetes.io/enforce=privileged \
  --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

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

3. Show that kube-proxy does not run:

   ```bash
   kubectl -n kube-system get daemonset kube-proxy
   ```

   Expected output: `Error from server (NotFound): daemonsets.apps "kube-proxy" not found`. Do not use
   `talosctl get nftableschains` for this check: it shows only the chains that Talos manages. kube-proxy
   writes its rules directly into the kernel, so they never show in that list.

4. Delete the objects:

   ```bash
   kubectl delete service web; kubectl delete deployment web
   ```

### Experiment 2: The Cilium agent uses KubePrism, not the Service

1. Show the API server address that the Cilium agent uses:

   ```bash
   kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.k8s-service-host}:{.data.k8s-service-port}{"\n"}'
   ```

   Expected output: `localhost:7445`.

2. Restart the Cilium agents. The agents do not need the `kubernetes` Service (10.96.0.1) to find the API
   server, because they connect to KubePrism on their own node:

   ```bash
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Show the KubePrism connection in the log of an agent:

   ```bash
   kubectl -n kube-system logs ds/cilium | grep -m3 -i 'localhost:7445'
   ```

   This experiment shows the configuration, not the failure case. The restart cannot remove the Service:
   `rollout restart` replaces one agent at a time, and Cilium keeps its BPF maps (and thus the Services)
   while an agent restarts. The real case without the Service is the first start, in step 1: Cilium
   started on nodes that had no kube-proxy and no Service implementation.

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
   helm template cilium cilium/cilium --version "${CILIUM_VERSION:-$(cilium version --client | sed -n 's/^cilium image (stable): v//p')}" \
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
   The container stops at once, and `docker logs <container>` shows `exec /sbin/init: argument list too long`.
   `talosctl cluster create` then stops with `panic: ParseAddr("invalid IP")`. A patch of 90 KB is sufficient
   to cause this, because base64 makes the data 4/3 larger. On QEMU and on real machines, there is no such
   limit, and the inline manifest is the recommended production method.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `cluster create` stops with `panic: ParseAddr("invalid IP")`. `docker logs cilium-controlplane-1` shows `exec /sbin/init: argument list too long`. | The machine configuration is more than 128 KiB in base64 (for example, an inline manifest). | Make the patch smaller. Use the CLI method, or a QEMU cluster for inline manifests (experiment 4). |
| `cluster create` waits at `waiting for apid to be ready` with `connection refused` from a worker. | The patch is in `patches/`, not in `patches/controlplane/`. A worker refuses `KubeProxyConfig`: `the following document kinds are only allowed on control plane machines`. | Keep the patch in `patches/controlplane/`. `docker logs cilium-worker-1` shows the error. |
| `cilium status --wait` does not end. The pods stay `Pending` or `ContainerCreating`. | Cilium did not start (for example, no image pull). | `kubectl -n kube-system get pods -o wide`, `kubectl -n kube-system describe pod <name>`, then the agent logs. |
| The agents fail with `operation not permitted` for a module. | A value list has `SYS_MODULE`, or a Cilium function needs a module that the host kernel does not have. | Use `values.yaml` as it is. In Docker, the host kernel must have the module. |
| CoreDNS does not answer when `bpf.masquerade: true`. | Known issue with the Talos host DNS forwarding (`forwardKubeDNSToHost`). | Do not set `bpf.masquerade`, or set `forwardKubeDNSToHost: false` in `ResolverConfig.hostDNS`. |
| The connectivity test stops with `timeout reached waiting for deployment cilium-test-1/client to become ready (last error: replicas count is zero)`. | The API server refused the test pods. Usually Pod Security. | Use `--namespace-labels` (see step 5). `kubectl -n cilium-test-1 get events --field-selector type=Warning` shows the reason. Delete the test namespaces before the next run: `kubectl get ns -o name | grep cilium-test | xargs kubectl delete`. |
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
