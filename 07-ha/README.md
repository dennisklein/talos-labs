# 07 – High availability: three control plane nodes, VIP, etcd and recovery

## Purpose

A production cluster has three (or five) control plane nodes. This stage makes such a cluster and shows the
parts that keep it available: the etcd quorum, a shared IP address (VIP) for the Kubernetes API and KubePrism
on each node. Then you do the operations of a control plane: etcd maintenance, the replacement of a node and
the recovery from a snapshot after the loss of quorum.

When you complete this stage, you know:

- Why etcd needs a quorum, and how many node failures a cluster can tolerate.
- How the Layer 2 VIP moves between the control plane nodes, and how long a failover takes.
- Why the VIP must not be the endpoint in the `talosconfig`.
- How KubePrism gives each node a local, highly available path to the API server.
- How to take an etcd snapshot, replace a control plane node and recover from a snapshot.

## Concepts

### etcd quorum

etcd uses the Raft protocol. A write needs a majority (quorum) of the members:

| Members | Quorum | Failures tolerated |
|---------|--------|--------------------|
| 1 | 1 | 0 |
| 2 | 2 | 0 |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |

Thus, use an odd number of control plane nodes. A fourth member adds no tolerance, but one more node that can
fail. On Talos, each control plane node runs one etcd member.

### Three ways to reach the Kubernetes API

```
                         kubectl (host)
                 /             |               \
   (1) load balancer     (2) VIP 10.5.7.50       direct 10.5.7.2..4
       10.5.7.1:6443         on one CP node
       (QEMU provisioner)    (etcd election)
                 \             |               /
          +--------------+ +--------------+ +--------------+
          | controlplane-1| | controlplane-2| | controlplane-3|      etcd: 3 members
          | apiserver    | | apiserver    | | apiserver    |
          +--------------+ +--------------+ +--------------+
                 ^               ^                ^
                 +--- (3) KubePrism 127.0.0.1:7445 on each node ---+
                      (kubelet, Cilium, pods with host network)
```

1. **External load balancer.** The QEMU provisioner runs one on the host (`10.5.7.1:6443`). It is the cluster
   endpoint in the configuration. In a data center, this is a hardware or software load balancer.
2. **Layer 2 VIP.** The control plane nodes elect one owner through etcd. The owner adds the address to its
   link and sends gratuitous ARP. No extra component is needed, but all control plane nodes must be in one
   layer 2 network.
3. **KubePrism.** Each node runs a small TCP load balancer on `127.0.0.1:7445`. It knows all API servers
   from the discovery data. It is for clients on the node, not for clients outside the cluster.

### Why the VIP is not the Talos endpoint

The VIP exists only while etcd works. If etcd fails, the VIP goes away. You then need the Talos API to repair
etcd. Thus, the `talosctl` endpoints are the node addresses (or a load balancer that does not depend on
etcd).

### VIP failover

| Event | Failover time |
|-------|---------------|
| Graceful shutdown or reboot of the owner | Almost immediate: the owner releases the election. |
| Crash, power loss or freeze of the owner | Up to about one minute: the election lease must expire. |

The long time for a crash prevents two owners at the same time (split brain).

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `ha` |
| Provisioner | QEMU, preset `iso` |
| Nodes | `ha-controlplane-1..3` (10.5.7.2 to 10.5.7.4), `ha-worker-1` (10.5.7.5) |
| Network | bridge, `10.5.7.0/24`, gateway and load balancer `10.5.7.1` |
| VIP | `10.5.7.50` on `net0` (the alias of `enp0s6`) of the control plane nodes |
| Memory | 2 GiB per VM, 8 GiB in total |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=ha`, `SUBNET`, `VIP`, `TALOSCONFIG`, `KUBECONFIG`, tasks `up`, `check` and `down`. |
| `patches/controlplane/vip.yaml` | `Layer2VIPConfig` for `10.5.7.50` on `net0`, and the VIP in `KubeAPIServerConfig.certExtraSANs`. |

## Procedure

Do the steps in the stage folder (`07-ha/`).

### Step 1: Start the lab

```bash
mise run up
```

The task makes four VMs and runs `check`. Expected output of the etcd members (the IDs are random):

```
NODE       ID                 HOSTNAME            PEER URLS               CLIENT URLS             LEARNER
10.5.7.2   7d2c54c5d5ee42a4   ha-controlplane-2   https://10.5.7.3:2380   https://10.5.7.3:2379   false
10.5.7.2   9106966f3c0743a6   ha-controlplane-3   https://10.5.7.4:2380   https://10.5.7.4:2379   false
10.5.7.2   f3ff2153a4230f63   ha-controlplane-1   https://10.5.7.2:2380   https://10.5.7.2:2379   false
```

### Step 2: Examine the talosconfig endpoints

```bash
talosctl config info
```

Expected output:

```
Current context:     ha
Nodes:               10.5.7.2
Endpoints:           10.5.7.2, 10.5.7.3, 10.5.7.4
Roles:               os:admin
Certificate expires: 1 year from now (...)
```

The endpoints are the three control plane addresses, not the VIP. `talosctl` uses one of them, and another
one if it cannot connect.

### Step 3: Examine etcd

```bash
talosctl -n 10.5.7.2,10.5.7.3,10.5.7.4 etcd status
talosctl -n 10.5.7.2,10.5.7.3,10.5.7.4 service etcd
```

Expected output of the first command (example):

```
NODE       MEMBER             DB SIZE   IN USE            LEADER             RAFT INDEX   RAFT TERM   RAFT APPLIED INDEX   LEARNER   PROTOCOL   STORAGE   ERRORS
10.5.7.3   7d2c54c5d5ee42a4   1.6 MB    1.6 MB (99.74%)   f3ff2153a4230f63   736          2           736                  false     3.7.2      3.7.0
10.5.7.4   9106966f3c0743a6   1.6 MB    1.6 MB (99.48%)   f3ff2153a4230f63   736          2           736                  false     3.7.2      3.7.0
10.5.7.2   f3ff2153a4230f63   1.6 MB    1.6 MB (99.74%)   f3ff2153a4230f63   736          2           736                  false     3.7.2      3.7.0
```

All members show the same leader and the same raft index. `PROTOCOL` is the etcd version, `STORAGE` the
version of the data format.

### Step 4: Find the VIP owner

```bash
talosctl -n 10.5.7.2,10.5.7.3,10.5.7.4 get addresses | grep -E 'NODE|10.5.7.50'
```

Expected output (example):

```
NODE       NAMESPACE   TYPE            ID                      VERSION   ADDRESS        LINK
10.5.7.2   network     AddressStatus   enp0s6/10.5.7.50/32     1         10.5.7.50/32   enp0s6
```

Only one node has the address. The status shows the link name `enp0s6`; `net0` in the patch is its alias. Use the VIP:

```bash
kubectl --server "https://$VIP:6443" get nodes
```

The command works because the VIP is in the certificate (`certExtraSANs`). Examine the certificate:

```bash
openssl s_client -connect "$VIP:6443" </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```

Expected output (part):

```
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, ..., DNS:ha-controlplane-1, IP Address:10.5.7.1, IP Address:10.5.7.2, IP Address:10.5.7.50, ...
```

### Step 5: Examine KubePrism

```bash
talosctl -n 10.5.7.5 get kubeprismstatuses
talosctl -n 10.5.7.5 get kubeprismendpoints -o yaml | yq .spec
```

Expected output:

```
NODE       NAMESPACE   TYPE              ID                 VERSION   HOST             HEALTHY
10.5.7.5   k8s         KubePrismStatus   k8s-loadbalancer   2         127.0.0.1:7445   true
endpoints:
  - host: 10.5.7.1
    port: 6443
  - host: 10.5.7.2
    port: 6443
  - host: 10.5.7.50
    port: 6443
  - host: 10.5.7.3
    port: 6443
  - host: 10.5.7.4
    port: 6443
```

The worker knows the three API servers, the cluster endpoint (the load balancer `10.5.7.1`) and the VIP.
Its kubelet uses `https://127.0.0.1:7445`.

## Experiments

Do the experiments after the procedure, in the sequence below.

### Experiment 1: VIP failover after a reboot

1. In a second terminal, send a request to the VIP each second:

   ```bash
   while true; do
     printf '%s ' "$(date +%T)"; kubectl --server "https://$VIP:6443" --request-timeout 2s get --raw /readyz || echo
     sleep 1
   done
   ```

2. Reboot the VIP owner (in the example `10.5.7.3`):

   ```bash
   talosctl -n 10.5.7.3 reboot
   ```

3. In the second terminal, look for failed requests. Expected result: no failure (in the test: 0 of 46
   requests). The owner releases the VIP before it stops, and another node takes it at once.

4. Find the new owner (step 4 of the procedure).

### Experiment 2: VIP failover after a freeze

1. Keep the loop of experiment 1 running.

2. Find the VIP owner. Freeze its VM with the QEMU monitor (in the example `ha-controlplane-2`):

   ```bash
   echo stop | sudo socat - UNIX-CONNECT:build/state/ha/ha-controlplane-2.monitor
   ```

   The VM stops at once, as after a crash. It does not release the VIP.

3. Count the failed requests in the second terminal. Expected result: failures for approximately 60
   seconds. Then another node takes the VIP. In the test:

   ```
   11:16:43 Unable to connect to the server: context deadline exceeded
   ...
   11:17:43 Unable to connect to the server: dial tcp 10.5.7.50:6443: connect: no route to host
   ```

4. Show the etcd status from a node that runs (not the frozen node):

   ```bash
   talosctl -n 10.5.7.2 etcd status
   talosctl -n 10.5.7.2 etcd members
   ```

   The member has a leader, and the list still has three members. Two of three members are a quorum: the
   cluster works. Do not send requests to the frozen node: they wait until their timeout.

5. Continue the VM:

   ```bash
   echo cont | sudo socat - UNIX-CONNECT:build/state/ha/ha-controlplane-2.monitor
   ```

   The node does not take the VIP back. There is no reason to move it again.

6. The clock of the VM stopped during the freeze. Thus, it is behind by the freeze time. Until Talos
   corrects the clock, the TLS connections to and from this node fail:

   - Requests to the node: `remote error: tls: expired certificate`.
   - Requests through the node (it is the endpoint):
     `x509: certificate has expired or is not yet valid: current time ... is before ...`.

   Watch the time of the node through another endpoint:

   ```bash
   talosctl -e 10.5.7.2 -n 10.5.7.3 time
   ```

   In the test (a freeze of 2 minutes), the requests failed for about 80 seconds after `cont`. Then the
   node time was still 2 minutes behind the NTP server time, and 20 seconds later Talos had corrected it:

   ```
   NODE       NTP-SERVER            NODE-TIME                                 NTP-SERVER-TIME
   10.5.7.3   time.cloudflare.com   2026-10-26 20:19:02.193684323 +0000 UTC   2026-10-26 20:21:02.313138228 +0000 UTC
   10.5.7.3   time.cloudflare.com   2026-10-26 20:21:22.51020879 +0000 UTC    2026-10-26 20:21:22.499458349 +0000 UTC
   ```

   Continue with experiment 3 when the time is correct.

### Experiment 3: etcd maintenance

1. Take a snapshot:

   ```bash
   talosctl -n 10.5.7.2 etcd snapshot build/etcd.snapshot
   ```

   Expected output (example):

   ```
   etcd snapshot saved to "build/etcd.snapshot" (2764832 bytes)
   snapshot info: hash 4a6791cf, revision 1453, total keys 477, total size 2764800
   ```

2. Move the leadership. Use the node that is the leader now:

   ```bash
   talosctl -n 10.5.7.3 etcd forfeit-leadership
   talosctl -n 10.5.7.2,10.5.7.3,10.5.7.4 etcd status
   ```

   `forfeit-leadership` prints nothing. All members show a new leader, and `RAFT TERM` increases by 1 (a
   new election).

3. Defragment one member at a time, then check the alarms:

   ```bash
   talosctl -n 10.5.7.4 etcd defrag
   talosctl -n 10.5.7.4 etcd status
   talosctl -n 10.5.7.2 etcd alarm list
   ```

   `defrag` prints nothing. `DB SIZE` of the member becomes smaller (in the test: 2.8 MB to 2.6 MB), and
   `IN USE` is near 100 %. `alarm list` prints nothing when there is no alarm (for example `NOSPACE`).

   `defrag` blocks the member while it runs. Do not defragment all members at the same time.

### Experiment 4: Replace a control plane node

1. Keep a copy of the control plane configuration. All control plane nodes of this cluster have the same
   configuration: it has no fixed host name (`HostnameConfig` with `auto: stable`):

   ```bash
   talosctl -n 10.5.7.2 get mc v1alpha1 -o jsonpath='{.spec}' > build/controlplane.yaml
   ```

2. Reset `ha-controlplane-3`. The graceful reset removes its etcd member first:

   ```bash
   talosctl -n 10.5.7.4 reset --reboot
   talosctl -n 10.5.7.2 etcd members
   ```

   `reset` waits until the node is back (`post check passed`). Two members remain. The node boots the ISO
   and waits in maintenance mode: `talosctl -n 10.5.7.4 get machinestatus --insecure` shows
   `stage: maintenance`.

3. Install the node again, as a new machine:

   ```bash
   talosctl -n 10.5.7.4 apply-config --insecure -f build/controlplane.yaml
   ```

   Expected output: `Applied configuration without a reboot`. The node installs Talos and reboots.

4. Wait until etcd has three members again:

   ```bash
   watch -n 5 talosctl -n 10.5.7.2 etcd members      # stop with Ctrl+C
   mise run check
   ```

   In the test, etcd had three members again after about 80 seconds. The new member has a new ID and the old
   host name. It joins as a *learner* first, and becomes a voting member when it has the data. In a small
   cluster this is too fast to see.

### Experiment 5: Recover from a snapshot after the loss of quorum

1. Make a ConfigMap, take a snapshot, then make a second ConfigMap:

   ```bash
   kubectl create configmap before-snapshot --from-literal=note=kept
   talosctl -n 10.5.7.2 etcd snapshot build/etcd.snapshot
   kubectl create configmap after-snapshot --from-literal=note=lost
   ```

2. Destroy etcd on all control plane nodes at the same time. Wipe the EPHEMERAL partition (it contains
   `/var/lib/etcd`). Each node is its own endpoint, and `--wait=false` does not wait for the node:

   ```bash
   for n in 10.5.7.2 10.5.7.3 10.5.7.4; do
     talosctl -e "$n" -n "$n" reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL --wait=false
   done
   ```

   Do not reset the nodes one after the other with `--wait`. Then two members always remain, and each node
   joins the cluster again as a new member: the quorum is never lost, and the data stays.

3. Wait until etcd is `Preparing` on all three nodes:

   ```bash
   talosctl -n 10.5.7.2,10.5.7.3,10.5.7.4 service etcd
   ```

   Expected output (part, for each node):

   ```
   NODE     10.5.7.4
   ID       etcd
   STATE    Preparing
   HEALTH   ?
   EVENTS   [Preparing]: Running pre state (...)
   ```

   etcd waits for a bootstrap. The Kubernetes API and the VIP are not available:
   `kubectl --server "https://$VIP:6443" get nodes` fails with `connect: no route to host`.

4. Recover on one node:

   ```bash
   talosctl -n 10.5.7.2 bootstrap --recover-from=build/etcd.snapshot
   ```

   Expected output (example):

   ```
   recovering from snapshot "build/etcd.snapshot": hash d94ffb9b, revision 2085, total keys 576, total size 4116480
   ```

5. Wait for the cluster and examine the ConfigMaps:

   ```bash
   mise run check
   kubectl get configmap before-snapshot after-snapshot
   ```

   Expected output:

   ```
   NAME              DATA   AGE
   before-snapshot   1      17m
   Error from server (NotFound): configmaps "after-snapshot" not found
   ```

   `before-snapshot` exists. `after-snapshot` is `NotFound`: it was written after the snapshot. The other two
   nodes joined the recovered etcd cluster without a bootstrap. All three members have new IDs.

6. Delete the ConfigMap:

   ```bash
   kubectl delete configmap before-snapshot
   ```

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| No node has the VIP. | etcd is not healthy, or the link name is wrong. | `talosctl -n 10.5.7.2 service etcd`. `talosctl -n 10.5.7.2 get links` must show the alias `net0`. |
| `kubectl --server https://10.5.7.50:6443` fails with `x509: certificate is valid for ...`. | The VIP is not in `certExtraSANs`. | Check `patches/controlplane/vip.yaml`. The API server gets a new certificate after the patch. |
| The VMs do not start: `cannot allocate memory`. | Not enough RAM on the host. | The stage needs about 8 GiB free. Close other stages (`mise run down-all`). |
| `etcd snapshot` fails. | No quorum. | Copy the database file: `talosctl -n <node> cp /var/lib/etcd/member/snap/db build/`, then recover with `--recover-skip-hash-check`. |
| `bootstrap --recover-from` fails with `etcd data directory is not empty`. | etcd runs with data: the nodes were reset one after the other, and the quorum was never lost. | Reset all three nodes at the same time (step 2 of experiment 5). |
| After a freeze, requests fail with `x509: certificate has expired or is not yet valid`. | The clock of the frozen VM is behind. | Wait until Talos corrects the time (`talosctl -e 10.5.7.2 -n <node> time`), or use another endpoint (`-e`). |
| `socat: command not found`. | `socat` is not installed on the host. | Install `socat`. |

## Clean up

```bash
mise run down
```

## References

- Virtual IP: https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip
- `Layer2VIPConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/layer2vipconfig
- KubePrism: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism
- etcd maintenance: https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/etcd-maintenance
- Disaster recovery: https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery
- Scale down: https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-down
