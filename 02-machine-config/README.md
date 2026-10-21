# 02 – Machine configuration: documents, patches, apply modes

## Purpose

Stage [01](../01-basic/README.md) used the configuration that `talosctl cluster create` made. This stage
looks inside the machine configuration and changes it, first as a file and then on running nodes.

When you complete this stage, you know:

- What the secrets bundle is and how `talosctl gen config` makes the files `controlplane.yaml`,
  `worker.yaml` and `talosconfig`.
- How a Talos 1.14 machine configuration is made of many small *documents*.
- How a strategic merge patch adds, changes and deletes documents.
- Why JSON patches (RFC 6902) do not work on a multi-document configuration.
- How to check a configuration with `talosctl validate`.
- The apply modes `auto`, `no-reboot`, `staged` and `try`, and the `--dry-run` option.

## Concepts

### From secrets to machine configuration

```
 talosctl gen secrets            secrets.yaml
   (CAs, tokens, keys)               |
                                     v
 talosctl gen config <name> <endpoint> --with-secrets secrets.yaml [--config-patch ...]
                                     |
          +--------------------------+---------------------------+
          v                          v                           v
   controlplane.yaml            worker.yaml                 talosconfig
   (all CAs with keys,          (CA certificates only,      (client certificate
    etcd, API server, ...)       join token)                 for talosctl, os:admin)
```

- The **secrets bundle** has the cluster CAs (Talos API, Kubernetes, etcd, aggregator), the service account
  key, the tokens and the discovery identity. Keep it safe. With it you can make more nodes for the same
  cluster.
- `controlplane.yaml` has the private keys of the CAs. `worker.yaml` has only what a worker needs to join.
- Without `--with-secrets`, `gen config` makes new secrets each time. Thus, two runs give two different
  clusters.

### A configuration is a list of documents

In Talos 1.14, the machine configuration is a multi-document YAML file. The first document is the
`v1alpha1` document. It has no `kind` and keeps the `machine:` and `cluster:` sections that have no new
document yet (for example `machine.token`, `machine.ca`, `cluster.etcd`). All other settings are in typed
documents with `apiVersion` and `kind`:

```
 controlplane.yaml (example, shortened)
 +-----------------------------------------------------------+
 | version: v1alpha1          machine: {type, token, ca}     |   v1alpha1 document
 |                            cluster: {token, etcd}         |
 |-----------------------------------------------------------|
 | kind: DiscoveryServiceConfig    endpoint                  |
 | kind: UnattendedInstallConfig   installer image, disk     |   node
 | kind: ResolverConfig            host DNS                  |
 | kind: VolumeConfig  EPHEMERAL   mount options             |
 | kind: HostnameConfig            auto: stable              |
 | kind: SecurityProfileConfig     workloadIsolation: true   |
 |-----------------------------------------------------------|
 | kind: KubeClusterConfig         name, endpoint            |
 | kind: KubeNodeConfig            labels, taints            |   Kubernetes
 | kind: KubeletConfig             image                     |
 | kind: KubeNetworkConfig         pod and service subnets   |
 | kind: KubeAPIServerConfig       image                     |   control plane only
 | kind: KubeProxyConfig           mode, enabled             |
 | kind: KubeFlannelCNIConfig      VXLAN, port 4789          |
 | ...                                                       |
 +-----------------------------------------------------------+
```

A document is identified by `kind`, and by `name` for kinds that can occur more than one time (for example
`StaticHostConfig`, `EtcFileConfig`, `VolumeConfig`). Older `v1alpha1` fields such as `cluster.network` or
`machine.kubelet` still work, but they are deprecated. A configuration cannot have the old field and the new
document for the same setting.

### Strategic merge patches

A strategic merge patch looks like a part of the configuration. Talos merges each patch document into the
document with the same `kind` (and `name`). If there is no such document, Talos adds the patch document.

```
 machine config                    patch                       result
 +----------------------+         +----------------------+    +----------------------+
 | kind: KubeNodeConfig |  merge  | kind: KubeNodeConfig |    | kind: KubeNodeConfig |
 | labels:              | <------ | labels:              | => | labels:              |
 |   node-role...: ""   |         |   lab.../tier: blue  |    |   node-role...: ""   |
 +----------------------+         +----------------------+    |   lab.../tier: blue  |
                                                              +----------------------+
 (no StaticHostConfig)     add    | kind: StaticHostConfig  => new document
                                  | name: 10.5.2.200     |

 | kind: EtcFileConfig  |  delete | kind: EtcFileConfig  | => document removed
 | name: lab/motd.conf  | <------ | name: lab/motd.conf  |
                                  | $patch: delete       |
```

Rules:

- Maps are merged key by key. Lists are appended (some lists, for example `podSubnets`, are replaced).
- `$patch: delete` deletes a field or a complete document. You cannot delete the `v1alpha1` document.
- JSON patches (RFC 6902, a list of `op`/`path`/`value`) work only on a configuration with only the
  `v1alpha1` document. A Talos 1.14 configuration has many documents. Thus, use strategic merge patches.

### Where patches apply

| Command | Applies the patch to |
|---------|----------------------|
| `talosctl gen config --config-patch @p.yaml` | the generated files |
| `talosctl cluster create ... --config-patch @p.yaml` | the generated configuration, before the nodes start |
| `talosctl machineconfig patch file.yaml -p @p.yaml` | a local file |
| `talosctl patch mc -n <node> -p @p.yaml` | the configuration of a running node |
| `talosctl edit mc -n <node>` | the configuration of a running node, in your editor |
| `talosctl apply-config -n <node> -f file.yaml` | replaces the configuration of a running node |

### Apply modes

In Talos 1.14, a running node applies a new configuration without a reboot. The `--mode=reboot` option was
removed. The modes are:

```
              apply now   keeps the change   needs a reboot
 auto            yes           yes                no          (default)
 no-reboot       yes           yes                no          (fails if a reboot were necessary)
 try             yes           only until the     no          (default timeout 1m, then Talos
                               timeout                         reverts the configuration)
 staged          no            yes                yes         (the node uses it after the next reboot)
```

- `--dry-run` shows the difference and what Talos would do. It changes nothing.
- `try` is a safety net. If the change cuts your access (for example a wrong firewall rule), Talos reverts it.
  To keep a `try` change, apply the same configuration again without `try`.
- Some settings are read only when a service starts, for example `cluster.etcd` or kernel module parameters.
  Talos applies the configuration, but you must reboot the node to use these settings.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `config` |
| Provisioner | Docker |
| Nodes | `config-controlplane-1` (10.5.2.2), `config-worker-1` (10.5.2.3) |
| Docker network | `config`, `10.5.2.0/24` |
| CNI, kube-proxy | Flannel, kube-proxy (Talos defaults) |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=config`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `up`, `check` and `down`. |
| `examples/node-labels.yaml` | Merge patch: adds a label to `KubeNodeConfig`. |
| `examples/static-host.yaml` | New `StaticHostConfig` document: an `/etc/hosts` entry. |
| `examples/etc-file.yaml` | New `EtcFileConfig` document: the file `/etc/lab/motd.conf`. |
| `examples/etc-file-delete.yaml` | Deletes the `EtcFileConfig` document. |
| `examples/cert-sans.yaml` | Merge patch for the `v1alpha1` document: an extra Talos API certificate name. |
| `examples/cert-sans.json6902.yaml` | The same change as a JSON patch. Talos refuses it. |
| `examples/dns-over-tls.yaml` | `ResolverConfig` with DNS over TLS. For the `try` mode. |
| `examples/invalid.yaml` | A patch that is not valid. Talos refuses it. |

## Procedure

Do the steps in the stage folder (`02-machine-config/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task makes the cluster (1 control plane node, 1 worker) and runs `check`. The `check` task shows
the `MachineConfig` resource of each node. Expected output (example, part):

```
NODE       NAMESPACE   TYPE            ID         VERSION
10.5.2.2   config      MachineConfig   v1alpha1   1
10.5.2.3   config      MachineConfig   v1alpha1   1
```

The resource ID is `v1alpha1`. It holds the complete multi-document configuration. `VERSION` increases
with each change.

### Step 2: Make a configuration by hand

This step does not touch the cluster. It shows what `talosctl cluster create` did for you.

1. Make a secrets bundle:

   ```bash
   talosctl gen secrets -o build/secrets.yaml
   ```

2. Make the configuration files. `--with-docs=false --with-examples=false` removes the comments:

   ```bash
   talosctl gen config demo https://10.5.2.2:6443 --with-secrets build/secrets.yaml \
     --with-docs=false --with-examples=false -o build/gen
   ```

   Expected output:

   ```
   generating PKI and tokens
   Created build/gen/controlplane.yaml
   Created build/gen/worker.yaml
   Created build/gen/talosconfig
   ```

3. List the documents of each file:

   ```bash
   yq -N '.kind // "(v1alpha1)"' build/gen/controlplane.yaml
   yq -N '.kind // "(v1alpha1)"' build/gen/worker.yaml
   ```

   `controlplane.yaml` has about 30 documents. `worker.yaml` has about 15. Only the control plane has the
   documents for the API server, the controller manager, the scheduler, kube-proxy, Flannel and CoreDNS.

4. Find the private keys. Only `controlplane.yaml` has the CA keys:

   ```bash
   grep -c 'key:' build/gen/controlplane.yaml build/gen/worker.yaml
   ```

### Step 3: Validate a configuration

```bash
talosctl validate --config build/gen/worker.yaml --mode container --strict
talosctl validate --config build/gen/worker.yaml --mode metal --strict
```

Expected output:

```
build/gen/worker.yaml is valid for container mode
build/gen/worker.yaml is valid for metal mode
```

The mode is the platform: `container` (Docker), `metal` (bare metal and QEMU) or `cloud`. Some settings are
valid only on some platforms.

### Step 4: Patch a file

1. Add a node label to a copy of the worker file:

   ```bash
   cat examples/node-labels.yaml
   talosctl machineconfig patch build/gen/worker.yaml -p @examples/node-labels.yaml -o build/gen/worker-blue.yaml
   ```

2. Compare the files:

   ```bash
   diff build/gen/worker.yaml build/gen/worker-blue.yaml
   ```

   Expected output (example):

   ```
   > lab.example.com/tier: blue
   ```

   Talos merged the `labels` map. The other labels stay.

### Step 5: Read the configuration of a running node

```bash
talosctl -n 10.5.2.3 get machineconfig v1alpha1 -o jsonpath='{.spec}' > build/worker-running.yaml
yq -N '.kind // "(v1alpha1)"' build/worker-running.yaml
yq 'select(.kind == "KubeNodeConfig")' build/worker-running.yaml
```

`talosctl cluster create` added some documents for Docker (for example a `ResolverConfig` with
`forwardKubeDNSToHost`). Use this method to back up the configuration of a node.

### Step 6: Patch a running node

1. Show what the label patch would change on the worker. `--dry-run` changes nothing:

   ```bash
   talosctl -n 10.5.2.3 patch mc --dry-run -p @examples/node-labels.yaml
   ```

   Expected output (example):

   ```
   Dry run summary:
   Applied configuration without a reboot (skipped in dry-run).

   Config diff:

   --- a
   +++ b
   @@ ... @@
    kind: KubeNodeConfig
    labels:
   +    lab.example.com/tier: blue
   ```

2. Apply the patch:

   ```bash
   talosctl -n 10.5.2.3 patch mc -p @examples/node-labels.yaml
   ```

   Expected output:

   ```
   patched MachineConfigs.config.talos.dev/v1alpha1 at the node 10.5.2.3
   Applied configuration without a reboot
   ```

3. After some seconds, the kubelet registers the label:

   ```bash
   kubectl get node config-worker-1 -L lab.example.com/tier
   ```

   ```
   NAME              STATUS   ROLES    AGE   VERSION   TIER
   config-worker-1   Ready    <none>   9m    v1.37.1   blue
   ```

### Step 7: Use the try mode

1. Add an `/etc/hosts` entry in `try` mode, with a timeout of 45 seconds:

   ```bash
   talosctl -n 10.5.2.3 patch mc --mode try --timeout 45s -p @examples/static-host.yaml
   ```

   Expected output:

   ```
   patched MachineConfigs.config.talos.dev/v1alpha1 at the node 10.5.2.3
   Applied configuration without a reboot
   The config is applied in 'try' mode and will be automatically reverted back in 45s
   ```

2. Read the file at once:

   ```bash
   talosctl -n 10.5.2.3 read /etc/hosts
   ```

   The file has the line `10.5.2.200 registry.lab.example.com`.

3. Wait 45 seconds. Read the file again:

   ```bash
   sleep 50; talosctl -n 10.5.2.3 read /etc/hosts
   ```

   The line is gone. Talos reverted the configuration.

4. Apply the same patch without `try`. Now the change stays:

   ```bash
   talosctl -n 10.5.2.3 patch mc -p @examples/static-host.yaml
   talosctl -n 10.5.2.3 get statichosts
   ```

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in the
state of the procedure.

### Experiment 1: Add and delete a document

1. Add the `EtcFileConfig` document to the worker:

   ```bash
   talosctl -n 10.5.2.3 patch mc -p @examples/etc-file.yaml
   talosctl -n 10.5.2.3 read /etc/lab/motd.conf
   ```

   Expected output of the second command:

   ```
   message = "configured by a machine config document"
   ```

2. Show the status resource of the file:

   ```bash
   talosctl -n 10.5.2.3 get etcfilestatuses
   ```

3. Delete the document. Talos removes the file:

   ```bash
   cat examples/etc-file-delete.yaml
   talosctl -n 10.5.2.3 patch mc -p @examples/etc-file-delete.yaml
   talosctl -n 10.5.2.3 read /etc/lab/motd.conf
   ```

   The last command fails with `no such file or directory`.

### Experiment 2: JSON patches and the v1alpha1 document

1. Try the JSON patch on the control plane node:

   ```bash
   cat examples/cert-sans.json6902.yaml
   talosctl -n 10.5.2.2 patch mc --dry-run -p @examples/cert-sans.json6902.yaml
   ```

   The command fails. The error message contains:

   ```
   JSON6902 patches are not supported for multi-document machine configuration
   ```

2. Make the same change with a strategic merge patch. A patch without `kind` applies to the `v1alpha1`
   document:

   ```bash
   cat examples/cert-sans.yaml
   talosctl -n 10.5.2.2 patch mc -p @examples/cert-sans.yaml
   ```

3. Talos makes a new certificate for `apid`. Show the names in the certificate:

   ```bash
   talosctl -n 10.5.2.2 get certsans -o yaml
   ```

   The list `dnsNames` has `talos.lab.example.com`.

4. Remove the name again. `$patch: delete` on the list removes the complete list:

   ```bash
   talosctl -n 10.5.2.2 patch mc -p '{"machine": {"certSANs": {"$patch": "delete"}}}'
   ```

### Experiment 3: Try DNS over TLS

1. Show the DNS servers of the worker:

   ```bash
   talosctl -n 10.5.2.3 get resolvers -o yaml
   ```

   In Docker, the DNS server comes from the container platform.

2. Apply DNS over TLS to Quad9 in `try` mode, with the default timeout of 1 minute:

   ```bash
   cat examples/dns-over-tls.yaml
   talosctl -n 10.5.2.3 patch mc --mode try -p @examples/dns-over-tls.yaml
   talosctl -n 10.5.2.3 get resolvers -o yaml
   talosctl -n 10.5.2.3 get dnsupstreams
   ```

   The upstream is now `9.9.9.9` with the protocol DoT.

3. Test a name from a pod. The pod uses CoreDNS, which sends the request to the host DNS of Talos
   (`forwardKubeDNSToHost`):

   ```bash
   kubectl run dns --rm -it --restart=Never --image=busybox:1.37 \
     --overrides='{"spec":{"nodeName":"config-worker-1"}}' -- nslookup siderolabs.com
   ```

4. Wait 1 minute. The DNS server of the container platform is back:

   ```bash
   sleep 60; talosctl -n 10.5.2.3 get dnsupstreams
   ```

### Experiment 4: Talos refuses a configuration that is not valid

1. Validate the patched file locally:

   ```bash
   talosctl machineconfig patch build/gen/worker.yaml -p @examples/invalid.yaml -o build/gen/worker-invalid.yaml
   talosctl validate --config build/gen/worker-invalid.yaml --mode container
   ```

   Expected output:

   ```
   1 error occurred:
   	* KubeNodeConfig: invalid node labels: 1 error occurred:
   	* label value length exceeds limit of 63: "this-value-is-much-too-long-for-a-kubernetes-label-value-so-validation-fails"
   ```

2. Send the patch to the node:

   ```bash
   talosctl -n 10.5.2.3 patch mc -p @examples/invalid.yaml
   ```

   The node gives the same error. The configuration does not change (the `VERSION` of `get machineconfig`
   stays the same).

### Experiment 5: Edit in an editor

1. Open the configuration of the worker in your editor (`TALOS_EDITOR`, `EDITOR`, else `vi`):

   ```bash
   talosctl -n 10.5.2.3 edit mc --mode try
   ```

2. In the `KubeNodeConfig` document, change the label value `blue` to `green`. Save and close the editor.

3. Examine the label. After 1 minute, the value is `blue` again:

   ```bash
   kubectl get node config-worker-1 -L lab.example.com/tier
   ```

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `JSON6902 patches are not supported for multi-document machine configuration`. | The configuration has typed documents. | Use a strategic merge patch. |
| `failed to validate: ... is not supported in container mode`. | The setting needs a real machine (for example disks). | Use the setting in a QEMU stage. |
| A `try` change stays after the timeout. | You applied the configuration again without `try` in the timeout. | Apply the old configuration, or patch the change away. |
| The label is not on the Kubernetes node. | The Node Restriction admission plugin refuses some label prefixes (`kubernetes.io`, `k8s.io`) from a worker. | Use your own prefix, for example `lab.example.com/`. |
| `--mode=reboot` is unknown. | Talos 1.14 removed this mode. | Apply the change, then do `talosctl reboot`. |

## Clean up

```bash
mise run down
```

The files in `build/` (secrets, generated configuration) stay. They contain private keys. Delete them with
`rm -rf build` when you do not need them.

## References

- Configuration patches: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/patching
- Edit the machine configuration (apply modes): https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration
- Files under /etc: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/managing-etc-files
- DNS resolvers: https://docs.siderolabs.com/talos/v1.14/networking/configuration/resolvers
- Host DNS: https://docs.siderolabs.com/talos/v1.14/networking/host-dns
- Configuration reference: https://docs.siderolabs.com/talos/v1.14/reference/configuration/overview
