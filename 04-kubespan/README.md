# 04 – KubeSpan: a WireGuard mesh from the discovery service

## Purpose

KubeSpan connects all nodes of a cluster with WireGuard tunnels. Talos makes the keys, finds the peers and
sets the routes itself. This stage enables KubeSpan and shows each part: the discovery service, the
WireGuard peers, the routing machinery and the encrypted traffic on the wire.

This is the first stage with QEMU virtual machines: KubeSpan does not start in Docker (see
[Why QEMU](#why-qemu)). Before you start, install the QEMU host requirements (see the
[top-level README](../README.md#qemu-stages-04-to-09)).

When you complete this stage, you know:

- How the discovery service lets nodes find each other (identities, affiliates, members).
- How KubeSpan makes a WireGuard full mesh without manual key exchange.
- How Talos sends cluster traffic into the tunnel: nftables mark, routing rule, routing table 180.
- What `advertiseKubernetesNetworks` changes.
- Why KubeSpan does not work without discovery.
- When a peer is not `up` (`unknown` or `down`), and what happens to its traffic.

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
2. gets an address for the link `kubespan`: the cluster-specific IPv6 ULA prefix plus a part from the MAC
   address of the first physical link,
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
      mark 0x20 set (WireGuard's own UDP packet)?  --yes--> accept, normal routing (enp0s6)
      destination in the set of cluster addresses?  --no---> normal routing (enp0s6)
      | yes: clamp the TCP MSS to the KubeSpan MTU (outgoing only), set the firewall mark 0x40
      v
 routing rule (priority 32500): fwmark 0x40/0x60 --> table 180
      |
      v
 table 180: default routes (IPv4 and IPv6) dev kubespan
      |
      v
 WireGuard encrypts, marks its UDP packet 0x20 --> UDP 51820 to 10.5.4.4 on enp0s6
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
 enp0s6 frame: IP 10.5.4.3 -> 10.5.4.4  UDP 51820  [ WireGuard, encrypted:
                                                      IP 10.5.4.3 -> 10.5.4.4  UDP 4789 [ VXLAN:
                                                        IP 10.244.1.5 -> 10.244.2.7 (pod to pod) ] ]
```

### Why use KubeSpan

KubeSpan is for clusters where nodes are in different networks: two data centers, a cloud and an office, or
nodes behind NAT. The CNI then needs only node-to-node connectivity, and KubeSpan gives it, encrypted. In
this lab, all nodes are on one bridge, so the effect is only the encryption.

### Why QEMU

The KubeSpan identity needs the MAC address of the first *physical* link. Talos counts a link as physical
if it is an Ethernet link without a kind (`talosctl get links`, column `KIND`). In a Docker container, the
only link is `eth0` of kind `veth`. Thus, there is no physical link, Talos makes no KubeSpan identity, and
KubeSpan does not start. The configuration is valid, and no error shows: `kubespanidentities`,
`kubespanpeerspecs` and the link `kubespan` stay absent. In a QEMU VM, the link `enp0s6` is a virtio network
card, a physical link.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `kubespan` |
| Provisioner | QEMU, preset `iso`: boot from the ISO, unattended install to `/dev/vda` |
| Nodes | `kubespan-controlplane-1` (10.5.4.2), `kubespan-worker-1` (10.5.4.3), `kubespan-worker-2` (10.5.4.4) |
| Network | Bridge `talos<hash>`, `10.5.4.0/24`, gateway 10.5.4.1. Node link `enp0s6` (alias `net0`). |
| Memory | 2 GiB per VM, 6 GiB in total |
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

Do the steps in the stage folder (`04-kubespan/`). The VMs need HTTPS access to `discovery.talos.dev`.

### Step 1: Start the lab

```bash
mise run up
```

The `up` task asks for the `sudo` password, makes the VMs with `talosctl cluster create qemu --workers 2
--config-patch @patches/kubespan.yaml` and runs `check`. This takes 3 to 6 minutes. Expected output of the
peer status at the end (example):

```
NODE       NAMESPACE   TYPE                 ID                                             VERSION   LABEL                     ENDPOINT         STATE   RX       TX
10.5.4.2   kubespan    KubeSpanPeerStatus   8tIvcS6Qppx5r+tcpqrglxeHBPIPAJE+eiCIRK/ogk4=   3         kubespan-worker-1         10.5.4.3:51820   up      41548    138560
10.5.4.2   kubespan    KubeSpanPeerStatus   w2BPYPIwFg9BH91E6fBjBPys8NkHey7i6A5dFDpAQkg=   3         kubespan-worker-2         10.5.4.4:51820   up      159544   433300
10.5.4.3   kubespan    KubeSpanPeerStatus   Tzf3Z/+xnVUIL1313v6XiHzC3G1ew9+y2QLi9EBocG0=   4         kubespan-controlplane-1   10.5.4.2:51820   up      135344   40644
10.5.4.3   kubespan    KubeSpanPeerStatus   w2BPYPIwFg9BH91E6fBjBPys8NkHey7i6A5dFDpAQkg=   4         kubespan-worker-2         10.5.4.4:51820   up      392      364
...
```

Each node has two peers. All peers are `up`. The ID of a peer is its WireGuard public key. Between the two
workers, `RX` and `TX` are small: most traffic goes to and from the control plane node.

### Step 2: Examine the discovery resources

```bash
talosctl get identities
talosctl get affiliates
talosctl get members
```

`affiliates` and `members` have the same three nodes. The ID of an affiliate is the identity of the node.
With KubeSpan, the `ADDRESSES` of a member also have its KubeSpan address (example):

```
NODE       NAMESPACE   TYPE     ID                        VERSION   HOSTNAME                  MACHINE TYPE   OS                ADDRESSES
10.5.4.2   cluster     Member   kubespan-controlplane-1   3         kubespan-controlplane-1   controlplane   Talos (v1.14.4)   ["10.5.4.2","fd21:f31e:e988:3702:5c28:26ff:fecf:a312"]
10.5.4.2   cluster     Member   kubespan-worker-1         1         kubespan-worker-1         worker         Talos (v1.14.4)   ["10.5.4.3","fd21:f31e:e988:3702:e0fa:d8ff:fec0:fea8"]
10.5.4.2   cluster     Member   kubespan-worker-2         1         kubespan-worker-2         worker         Talos (v1.14.4)   ["10.5.4.4","fd21:f31e:e988:3702:f06a:caff:fe61:4717"]
```

Show the discovery documents in the configuration:

```bash
talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' \
  | yq 'select(.kind == "DiscoveryServiceConfig" or .kind == "KubeSpanConfig")'
```

### Step 3: Examine the KubeSpan identity and peers

```bash
talosctl -n 10.5.4.3 get kubespanidentities -o yaml
talosctl -n 10.5.4.3 get kubespanpeerspecs -o yaml
talosctl -n 10.5.4.3 get links enp0s6
```

Expected output of the first command (example, part):

```yaml
spec:
    address: fd21:f31e:e988:3702:e0fa:d8ff:fec0:fea8/128
    subnet: fd21:f31e:e988:3702::/64
    privateKey: GO0z...
    publicKey: 8tIvcS6Qppx5r+tcpqrglxeHBPIPAJE+eiCIRK/ogk4=
```

- `subnet` is the ULA prefix of the cluster. It comes from the cluster ID.
- The last 64 bits of `address` come from the MAC address of `enp0s6` (`e2:fa:d8:c0:fe:a8` gives
  `e0fa:d8ff:fec0:fea8`). This is why KubeSpan needs a physical link.
- `publicKey` is the peer ID on the other nodes.

Expected output of the second command (example, one peer):

```yaml
spec:
    address: fd21:f31e:e988:3702:5c28:26ff:fecf:a312
    allowedIPs:
        - 10.5.4.2/32
        - fd21:f31e:e988:3702:5c28:26ff:fecf:a312/128
    endpoints:
        - 10.5.4.2:51820
        - 203.0.113.10:51820
    label: kubespan-controlplane-1
```

- `allowedIPs` are the addresses that go into the tunnel to this peer: its node address and its KubeSpan
  address.
- `endpoints` has two entries. The first is the node address. The second is the public address of your
  host: the discovery service saw the connection of the node from this address (NAT) and published it. For
  nodes in different networks, the public address is the endpoint that works.

### Step 4: Examine the link, the routing rule and the table

1. Show the `kubespan` link:

   ```bash
   talosctl -n 10.5.4.3 get links kubespan -o yaml | yq '.spec | {"kind": .kind, "mtu": .mtu, "listenPort": .wireguard.listenPort}'
   ```

2. Show the routing rules and the routes of table 180:

   ```bash
   talosctl -n 10.5.4.3 get routingrulestatuses
   talosctl -n 10.5.4.3 get routes | grep -E 'NODE| 180/'
   ```

   Expected output (example):

   ```
   NODE       NAMESPACE   TYPE                ID            VERSION   SRC   DST   TABLE     PRIORITY
   10.5.4.3   network     RoutingRuleStatus   inet4/00000   1                     local     0
   10.5.4.3   network     RoutingRuleStatus   inet4/32500   1                     180       32500
   10.5.4.3   network     RoutingRuleStatus   inet4/32766   1                     main      32766
   10.5.4.3   network     RoutingRuleStatus   inet4/32767   1                     default   32767
   10.5.4.3   network     RoutingRuleStatus   inet6/00000   1                     local     0
   10.5.4.3   network     RoutingRuleStatus   inet6/32500   1                     180       32500
   10.5.4.3   network     RoutingRuleStatus   inet6/32766   1                     main      32766
   NODE       NAMESPACE   TYPE          ID                       VERSION   DESTINATION   GATEWAY   LINK       METRIC
   10.5.4.3   network     RouteStatus   180/inet4///1            1                                 kubespan   1
   10.5.4.3   network     RouteStatus   180/kubespan/inet6///1   1                                 kubespan   1
   ```

   One rule for each IP family (priority 32500) sends packets with the mark `0x40/0x60` to table 180. The
   status shows the table, not the mark. The route IDs start with the table. Table 180 has default routes
   (no destination) for IPv4 and IPv6 to the link `kubespan`.

3. Show the nftables chains of KubeSpan:

   ```bash
   talosctl -n 10.5.4.3 get nftableschains
   talosctl -n 10.5.4.3 get nftableschains kubespan_outgoing -o yaml
   ```

   Expected output of the second command (part):

   ```yaml
   spec:
       type: route
       hook: output
       rules:
           - matchMark:
               mask: 96          # 0x60
               value: 32         # 0x20: a WireGuard packet of KubeSpan
             verdict: accept
           - matchOIfName:
               interfaceName:
                   - lo
               operator: ==
             verdict: accept
           - matchDestinationAddress:
               includeSubnets:
                   - 10.5.4.2/32
                   - 10.5.4.4/32
             clampMSS:
               mtu: 1420
           - matchDestinationAddress:
               includeSubnets:
                   - 10.5.4.2/32
                   - 10.5.4.4/32
             setMark:
               mask: 4294967199  # keep all bits except 0x60
               xor: 64           # then set 0x40
             verdict: accept
   ```

   The `includeSubnets` lists are the cluster addresses: the `allowedIPs` of the peers. The chain
   `kubespan_prerouting` (hook `prerouting`) sets the same mark on packets that the node forwards, for
   example from pods. It has no `lo` rule and no MSS rule.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Capture the encrypted traffic

Talos has no `tcpdump`. `talosctl pcap` captures on the node and sends the packets to the client in pcap
format. `tcpdump` on the host reads and filters them.

1. Start a server pod on `kubespan-worker-1` and a client pod on `kubespan-worker-2`:

   ```bash
   kubectl run srv --image=nginx:1.29-alpine --overrides='{"spec":{"nodeName":"kubespan-worker-1"}}'
   kubectl run cli --image=curlimages/curl:8.17.0 --overrides='{"spec":{"nodeName":"kubespan-worker-2"}}' \
     --command -- sleep infinity
   kubectl wait --for=condition=Ready pod/srv pod/cli
   SRV=$(kubectl get pod srv -o jsonpath='{.status.podIP}'); echo "$SRV"
   ```

2. Capture on the link `enp0s6` of `kubespan-worker-1` for 15 seconds, and send a request in this time.
   Use the worker as endpoint (`-e`): then the capture stream goes directly from the worker to the host,
   outside of KubeSpan. Through the control plane endpoint, the stream itself goes through the tunnel and
   fills the capture.

   ```bash
   talosctl -e 10.5.4.3 -n 10.5.4.3 pcap -i enp0s6 --duration 15s -o - > build/enp0s6.pcap &
   sleep 3; kubectl exec cli -- curl -s -o /dev/null -w '%{http_code}\n' "http://$SRV"; wait $!
   ```

   Expected output: `200`. At the end of the capture, `talosctl` shows
   `rpc error: code = Canceled desc = stream terminated by RST_STREAM with error code: CANCEL`. This is
   normal.

3. Examine the capture:

   ```bash
   tcpdump -nr build/enp0s6.pcap 'udp port 51820 or udp port 4789' | head
   ```

   Expected output (example):

   ```
   IP 10.5.4.4.51820 > 10.5.4.3.51820: UDP, length 160
   IP 10.5.4.3.51820 > 10.5.4.4.51820: UDP, length 96
   IP 10.5.4.4.51820 > 10.5.4.3.51820: UDP, length 544
   ...
   ```

   All packets are WireGuard (port 51820). There is no VXLAN packet (port 4789) on `enp0s6`. The VXLAN
   packets are inside the tunnel.

4. Capture on the link `kubespan` in the same way. Here you see the VXLAN packets before encryption:

   ```bash
   talosctl -e 10.5.4.3 -n 10.5.4.3 pcap -i kubespan --duration 15s -o - > build/kubespan.pcap &
   sleep 3; kubectl exec cli -- curl -s -o /dev/null -w '%{http_code}\n' "http://$SRV"; wait $!
   tcpdump -nr build/kubespan.pcap 'udp port 4789' | head -4
   ```

   Expected output (example):

   ```
   IP 10.5.4.4.44006 > 10.5.4.3.vxlan: VXLAN, flags [I] (0x08), vni 1
   IP 10.244.2.2.51064 > 10.244.1.2.http: Flags [S], seq 185012781, win 65170, options [mss 1330,...], length 0
   ```

   The link `kubespan` has no Ethernet header (`link-type RAW`). `tcpdump` shows the port names `vxlan` and
   `http`. The inner TCP MSS is 1330: KubeSpan MTU 1420 minus 50 (VXLAN) minus 40 (IP and TCP).

5. Delete the pods:

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

### Experiment 4: A peer goes down

A peer is not `up` when its last WireGuard handshake is older than 275 seconds. Then KubeSpan tries the
next endpoint of the peer. After each try, the state is `unknown` for 15 seconds, then `down`, then KubeSpan
tries again. Thus, a peer that does not answer shows mostly `unknown`. By default (`allowDownPeerBypass: false`),
its traffic still goes into the tunnel and stops. Talos never sends it unencrypted.

1. Freeze the VM of `kubespan-worker-2` with the QEMU monitor:

   ```bash
   echo stop | sudo socat - UNIX-CONNECT:build/state/kubespan/kubespan-worker-2.monitor
   ```

2. Watch the peer status on the control plane node. Stop the watch with `Ctrl+C` when the state of
   `kubespan-worker-2` is not `up` (after approximately 5 minutes):

   ```bash
   talosctl -n 10.5.4.2 get kubespanpeerstatuses --watch
   ```

   The `RX` counter of `kubespan-worker-2` stops. Expected output after 10 minutes (part):

   ```
   NODE       NAMESPACE   TYPE                 ID      VERSION   LABEL               ENDPOINT         STATE     RX       TX
   10.5.4.2   kubespan    KubeSpanPeerStatus   O4Cq…   24        kubespan-worker-1   10.5.4.3:51820   up        134780   172212
   10.5.4.2   kubespan    KubeSpanPeerStatus   ZKXj…   24        kubespan-worker-2   10.5.4.4:51820   unknown   408484   824916
   ```

   `kubectl get nodes` shows `kubespan-worker-2` as `NotReady` after approximately 40 seconds, much earlier
   than KubeSpan.

3. Show that the address of the peer is still routed into the tunnel:

   ```bash
   talosctl -n 10.5.4.2 get nftableschains kubespan_outgoing -o yaml | grep -c 10.5.4.4
   ```

   The result is not `0` (in the test: `2`).

4. Continue the VM. After the next handshake (approximately 10 seconds), the state is `up` again, and the
   node is `Ready`:

   ```bash
   echo cont | sudo socat - UNIX-CONNECT:build/state/kubespan/kubespan-worker-2.monitor
   talosctl -n 10.5.4.2 get kubespanpeerstatuses
   kubectl get nodes
   ```

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `get members` shows only the local node. | The VM cannot reach `discovery.talos.dev:443`. | Check the internet access of the VMs (firewalld and Docker rows in the [host requirements](../README.md#qemu-stages-04-to-09)). A proxy is not supported for discovery in this lab. |
| Peer state stays `unknown` or `down`. | The host firewall blocks UDP 51820 on the bridge. | The bridge must be in the firewalld zone `trusted` (the `up` task does this). `sudo firewall-cmd --get-zone-of-interface=<bridge>`. |
| `kubespanidentities` is empty and the link `kubespan` does not exist, with no error. | The node has no physical link (for example, a Docker container: `eth0` is a `veth`). | Use VMs or real machines (see [Why QEMU](#why-qemu)). |
| `KubeSpan requires cluster discovery to be enabled`. | The configuration has `KubeSpanConfig` but no `DiscoveryServiceConfig`. | Keep a discovery service document. |
| TCP between pods works, but large UDP packets between pods are lost. | The VXLAN packets are larger than the KubeSpan MTU (1420). KubeSpan clamps only the TCP MSS. | Set the CNI MTU to 1420 minus the CNI overhead (VXLAN: 50, thus 1370). |
| `socat: command not found`. | `socat` is not installed on the host. | Install `socat`. |
| `tcpdump: command not found`. | `tcpdump` is not installed on the host. | Install `tcpdump`. |

## Clean up

```bash
mise run down
```

If you did not complete experiment 4, the VM is frozen. `mise run down` removes it too.

## References

- KubeSpan: https://docs.siderolabs.com/talos/v1.14/networking/kubespan
- KubeSpan design: https://docs.siderolabs.com/talos/v1.14/learn-more/kubespan
- Discovery service: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/discovery
- `KubeSpanConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/kubespanconfig
- `DiscoveryServiceConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/cluster/discoveryserviceconfig
