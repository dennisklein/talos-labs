# 04 – KubeSpan: a WireGuard mesh from the discovery service

## Purpose

KubeSpan connects all nodes of a cluster with WireGuard tunnels. Talos makes the keys, finds the peers and
sets the routes itself. This stage enables KubeSpan and shows each part: the discovery service, the
WireGuard peers, the routing machinery and the encrypted traffic on the wire.

When you complete this stage, you know:

- How the discovery service lets nodes find each other (identities, affiliates, members).
- How KubeSpan makes a WireGuard full mesh without manual key exchange.
- How Talos sends cluster traffic into the tunnel: nftables mark, routing rule, routing table 180.
- What `advertiseKubernetesNetworks` changes.
- Why KubeSpan does not work without discovery.

## Concepts

### Discovery service

Each node sends encrypted data about itself (the *affiliate* data) to a discovery service. The default is
the public service `https://discovery.talos.dev/`. The cluster ID and the cluster secret come from the
`DiscoveryIdentityConfig` document (made from the secrets bundle). The service sees only encrypted data. Only
nodes with the cluster secret can decrypt it.

```
                    discovery.talos.dev (TCP 443)
                    stores encrypted affiliate data per cluster ID
                 ^            ^            ^
     publish +   |            |            |   + read the others
                 |            |            |
          controlplane-1   worker-1     worker-2
          identity A       identity B   identity C
          WireGuard key    WireGuard    WireGuard
          addresses        key, ...     key, ...
```

Three resources show the steps:

| Resource | Content |
|----------|---------|
| `identities` | The ID of the local node (random, base62). |
| `affiliates` | All nodes that publish data with the same cluster ID: own data and data from the service. |
| `members` | Affiliates that are confirmed members of the cluster (host name, machine type, addresses). |

`talosctl health` and KubePrism also use the members list.

### KubeSpan

With `KubeSpanConfig.enabled: true`, each node:

1. makes a WireGuard key pair (the public key goes into the affiliate data),
2. gets an address from a cluster-specific IPv6 ULA prefix for the link `kubespan`,
3. makes one WireGuard peer for each other member, with the endpoints from the discovery data,
4. tries the endpoints until the handshake works (UDP 51820).

```
                  WireGuard full mesh (link "kubespan", UDP 51820)

               controlplane-1 (10.5.4.2)
                 /                    \
                /                      \
     worker-1 (10.5.4.3) ------------ worker-2 (10.5.4.4)
```

### How traffic goes into the tunnel

KubeSpan does not change the normal routes. It marks packets and uses policy routing:

```
 packet from the host or from a pod, destination 10.5.4.4
      |
      v
 nftables chains kubespan_prerouting / kubespan_outgoing
      mark 0x20 set (WireGuard's own UDP packet)?  --yes--> accept, normal routing (eth0)
      destination in the set of cluster addresses?  --no---> normal routing (eth0)
      | yes: clamp the TCP MSS to the KubeSpan MTU, set the firewall mark 0x40
      v
 routing rule (priority 32500): fwmark 0x40/0x60 --> table 180
      |
      v
 table 180: default routes (IPv4 and IPv6) dev kubespan
      |
      v
 WireGuard encrypts, marks its UDP packet 0x20 --> UDP 51820 to 10.5.4.4 on eth0
```

- The set of cluster addresses has the node addresses of all peers. By default, this is also true when a
  tunnel is down: the traffic to that peer stops, and Talos does not send it unencrypted.
  `allowDownPeerBypass: true` changes this: only peers that are `up` are in the set. With
  `advertiseKubernetesNetworks: true`, it also has the pod CIDRs of the peers.
- The WireGuard packets have the mark 0x20. The chains accept them without a change. Thus, they go out
  through the normal routes and do not loop into the tunnel.

In this stage, Flannel still makes its VXLAN tunnel (UDP 4789) between the node addresses. The node
addresses are in the KubeSpan set. Thus, the VXLAN packets go inside WireGuard:

```
 eth0 frame: IP 10.5.4.3 -> 10.5.4.4  UDP 51820  [ WireGuard, encrypted:
                                                    IP 10.5.4.3 -> 10.5.4.4  UDP 4789 [ VXLAN:
                                                      IP 10.244.1.5 -> 10.244.2.7 (pod to pod) ] ]
```

### Why use KubeSpan

KubeSpan is for clusters where nodes are in different networks: two data centers, a cloud and an office, or
nodes behind NAT. The CNI then needs only node-to-node connectivity, and KubeSpan gives it, encrypted. In
this lab, all nodes are on one Docker bridge, so the effect is only the encryption.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `kubespan` |
| Provisioner | Docker |
| Nodes | `kubespan-controlplane-1` (10.5.4.2), `kubespan-worker-1` (10.5.4.3), `kubespan-worker-2` (10.5.4.4) |
| Docker network | `kubespan`, `10.5.4.0/24` |
| KubeSpan | enabled on all nodes, UDP 51820, link `kubespan`, MTU 1420 |
| Discovery | `https://discovery.talos.dev/` (default) |
| CNI | Flannel (VXLAN inside KubeSpan), kube-proxy |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=kubespan`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `up`, `check` and `down`. |
| `patches/kubespan.yaml` | `KubeSpanConfig` with `enabled: true`, for all nodes. |
| `examples/advertise-pod-networks.yaml` | `advertiseKubernetesNetworks: true`. |
| `examples/no-discovery.yaml` | Deletes the discovery service document. Talos refuses it. |

## Procedure

Do the steps in the stage folder (`04-kubespan/`). The nodes need HTTPS access to `discovery.talos.dev`.

### Step 1: Start the lab

```bash
mise run up
```

The `up` task makes the cluster with `--config-patch @patches/kubespan.yaml` and runs `check`. Expected output
of the peer status at the end (example):

```
NODE       NAMESPACE   TYPE               ID                                             VERSION   LABEL                     ENDPOINT         STATE   RX       TX
10.5.4.2   kubespan    KubeSpanPeerStatus 0bGc...=                                       12        kubespan-worker-1         10.5.4.3:51820   up      183040   201432
10.5.4.2   kubespan    KubeSpanPeerStatus 9xT1...=                                       12        kubespan-worker-2         10.5.4.4:51820   up      176112   195880
10.5.4.3   kubespan    KubeSpanPeerStatus Hq2P...=                                       11        kubespan-controlplane-1   10.5.4.2:51820   up      ...
...
```

Each node has two peers. All peers are `up`.

### Step 2: Examine the discovery resources

```bash
talosctl get identities
talosctl get affiliates
talosctl get members
```

`affiliates` and `members` have the same three nodes. The ID of an affiliate is the identity of the node.

Show the discovery documents in the configuration:

```bash
talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' \
  | yq 'select(.kind == "DiscoveryServiceConfig" or .kind == "KubeSpanConfig")'
```

### Step 3: Examine the KubeSpan identity and peers

```bash
talosctl -n 10.5.4.3 get kubespanidentities -o yaml
talosctl -n 10.5.4.3 get kubespanpeerspecs
```

Expected output of the first command (example, part):

```yaml
spec:
    address: fd5e:13a2:7c40:7302:a0c3:e2ff:fe11:4b2a/128
    subnet: fd5e:13a2:7c40:7302::/64
    privateKey: ...
    publicKey: Hq2P...=
```

- `subnet` is the ULA prefix of the cluster. It comes from the cluster ID.
- `publicKey` is the peer ID on the other nodes.

### Step 4: Examine the link, the routing rule and the table

1. Show the `kubespan` link:

   ```bash
   talosctl -n 10.5.4.3 get links kubespan -o yaml | yq '.spec | {"kind": .kind, "mtu": .mtu, "listenPort": .wireguard.listenPort}'
   ```

2. Show the routing rules and the routes of table 180:

   ```bash
   talosctl -n 10.5.4.3 get routingrulestatuses
   talosctl -n 10.5.4.3 get routes | grep -E 'TABLE|180'
   ```

   One rule for each IP family sends packets with the mark `0x40/0x60` to table 180. Table 180 has default routes for IPv4 and
   IPv6 to the link `kubespan`.

3. Show the nftables chains of KubeSpan:

   ```bash
   talosctl -n 10.5.4.3 get nftableschains
   talosctl -n 10.5.4.3 get nftableschains kubespan_outgoing -o yaml
   ```

   The chain matches the destination address against the set of cluster addresses and sets the mark.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Capture the encrypted traffic

1. Start a server pod on `kubespan-worker-1` and a client pod on `kubespan-worker-2`:

   ```bash
   kubectl run srv --image=nginx:1.29-alpine --overrides='{"spec":{"nodeName":"kubespan-worker-1"}}'
   kubectl run cli --image=curlimages/curl:8.17.0 --overrides='{"spec":{"nodeName":"kubespan-worker-2"}}' \
     --command -- sleep infinity
   kubectl wait --for=condition=Ready pod/srv pod/cli
   SRV=$(kubectl get pod srv -o jsonpath='{.status.podIP}'); echo "$SRV"
   ```

2. In a second terminal, capture on `eth0` of `kubespan-worker-1`. The Talos image has no `tcpdump`. Thus,
   start a `netshoot` container in the network namespace of the node container:

   ```bash
   docker run --rm --net container:kubespan-worker-1 nicolaka/netshoot \
     tcpdump -ni eth0 -c 6 'udp port 51820 or udp port 4789'
   ```

3. In the first terminal, send a request:

   ```bash
   kubectl exec cli -- curl -s -o /dev/null -w '%{http_code}\n' "http://$SRV"
   ```

   Expected output: `200`.

4. Examine the capture. Expected output (example):

   ```
   IP 10.5.4.4.51820 > 10.5.4.3.51820: UDP, length 176
   IP 10.5.4.3.51820 > 10.5.4.4.51820: UDP, length 176
   ...
   ```

   All packets are WireGuard (port 51820). There is no VXLAN packet (port 4789) on `eth0`. The VXLAN packets
   are inside the tunnel.

5. Capture on the `kubespan` link. Here you see the VXLAN packets before encryption:

   ```bash
   docker run --rm --net container:kubespan-worker-1 nicolaka/netshoot tcpdump -ni kubespan -c 4 udp port 4789
   ```

   Send the request of step 3 again. Expected output (example):

   ```
   IP 10.5.4.4.41234 > 10.5.4.3.4789: VXLAN, flags [I] (0x08), vni 1
   IP 10.244.2.9.51334 > 10.244.1.6.80: Flags [S], ...
   ```

6. Delete the pods:

   ```bash
   kubectl delete pod srv cli
   ```

### Experiment 2: Advertise the pod networks

1. Show the networks that a peer advertises:

   ```bash
   talosctl -n 10.5.4.3 get kubespanpeerspecs -o yaml | yq '.spec | {"label": .label, "allowedIPs": .allowedIPs}'
   ```

   Each peer has only its node address (and its KubeSpan address).

2. Apply `advertiseKubernetesNetworks: true` on all nodes in `try` mode (2 minutes):

   ```bash
   talosctl -n 10.5.4.2,10.5.4.3,10.5.4.4 patch mc --mode try --timeout 2m -p @examples/advertise-pod-networks.yaml
   ```

3. Show the networks again:

   ```bash
   talosctl -n 10.5.4.3 get kubespanpeerspecs -o yaml | yq '.spec | {"label": .label, "allowedIPs": .allowedIPs}'
   ```

   Now each peer also has its pod CIDR (for example `10.244.2.0/24`). Pod traffic to other nodes goes into
   the tunnel directly. Use this when the CNI cannot route pod traffic between the networks of the nodes.

4. Wait 2 minutes. Talos reverts the change.

### Experiment 3: KubeSpan needs discovery

1. Try to remove the discovery service from a worker:

   ```bash
   cat examples/no-discovery.yaml
   talosctl -n 10.5.4.3 patch mc --dry-run -p @examples/no-discovery.yaml
   ```

   The command fails. The error message contains:

   ```
   KubeSpan requires cluster discovery to be enabled
   ```

   Without a registry, a node cannot get the public keys and endpoints of its peers.

### Experiment 4: A new peer joins the mesh

1. Make a fourth node with the same machine configuration as a worker. Read the configuration of
   `kubespan-worker-1`:

   ```bash
   talosctl -n 10.5.4.3 get machineconfig v1alpha1 -o jsonpath='{.spec}' > build/worker.yaml
   ```

2. Start a Talos container by hand, with the configuration in the environment variable `USERDATA` (this is
   what the Docker provisioner does):

   ```bash
   docker run -d --name kubespan-worker-3 --hostname kubespan-worker-3 --network kubespan --ip 10.5.4.10 \
     --privileged --security-opt seccomp=unconfined --read-only \
     --sysctl net.ipv6.conf.all.disable_ipv6=0 \
     --mount type=tmpfs,destination=/run --mount type=tmpfs,destination=/system --mount type=tmpfs,destination=/tmp \
     --mount type=volume,destination=/var --mount type=volume,destination=/system/state \
     --mount type=volume,destination=/opt \
     -e PLATFORM=container -e USERDATA="$(base64 -w0 build/worker.yaml)" \
     "ghcr.io/siderolabs/talos:$(talosctl version --client | awk '/Tag:/ {print $2; exit}')"
   ```

3. Wait until the node is a member, and the other nodes have a new peer:

   ```bash
   talosctl get members --watch          # stop with Ctrl+C when kubespan-worker-3 shows
   talosctl -n 10.5.4.2 get kubespanpeerstatuses
   kubectl get nodes
   ```

   No other node needed a change. The discovery service gave them the new key and endpoint.

4. Remove the node:

   ```bash
   kubectl delete node kubespan-worker-3
   docker rm -f -v kubespan-worker-3
   ```

   The member stays in the list until the discovery data expires (up to 30 minutes).

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `get members` shows only the local node. | The node cannot reach `discovery.talos.dev:443`. | Check the internet access of the Docker network. A proxy is not supported for discovery in this lab. |
| Peer state stays `unknown` or `down`. | UDP 51820 is blocked, or the host kernel has no WireGuard module. | `lsmod | grep wireguard` on the host. `sudo modprobe wireguard`. |
| `KubeSpan requires cluster discovery to be enabled`. | The configuration has `KubeSpanConfig` but no `DiscoveryServiceConfig`. | Keep a discovery service document. |
| TCP between pods works, but large UDP packets between pods are lost. | The VXLAN packets are larger than the KubeSpan MTU (1420). KubeSpan clamps only the TCP MSS. | Set the CNI MTU to 1420 minus the CNI overhead (VXLAN: 50, thus 1370). |
| Experiment 4: the container stops at once. | A mount or a flag is missing. | `docker logs kubespan-worker-3`. Compare with `docker inspect kubespan-worker-1`. |

## Clean up

```bash
mise run down
```

If you did not complete experiment 4, also do `docker rm -f -v kubespan-worker-3`.

## References

- KubeSpan: https://docs.siderolabs.com/talos/v1.14/networking/kubespan
- KubeSpan design: https://docs.siderolabs.com/talos/v1.14/learn-more/kubespan
- Discovery service: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/discovery
- `KubeSpanConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/kubespanconfig
- `DiscoveryServiceConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/cluster/discoveryserviceconfig
