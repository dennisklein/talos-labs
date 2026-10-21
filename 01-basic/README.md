# 01 – Basic: Talos in Docker

## Purpose

This stage makes the smallest useful Talos cluster. You operate it only through the Talos API. All other
stages start from what you learn here.

When you complete this stage, you know:

- Why Talos has no shell, no SSH and no package manager.
- How `talosctl cluster create docker` makes a cluster from Talos containers.
- The difference between an *endpoint* and a *node* in the `talosconfig` file.
- How to examine a node with `talosctl health`, `services`, `logs`, `containers` and `dashboard`.
- How Talos shows its state as *resources* (`talosctl get`).

## Concepts

### Talos is an API-managed operating system

Talos Linux is an operating system only for Kubernetes. It has no shell, no SSH server and no package manager.
The root file system is read-only (SquashFS). You do all work through a gRPC API (the Talos API), with the
`talosctl` client.

```
 Linux distribution                        Talos Linux
 +------------------------------+          +------------------------------+
 | ssh, bash, apt/dnf, systemd  |          | apid       (Talos API, :50000)|
 | your scripts, cron, ...      |          | machined   (PID 1, controllers)|
 | kubelet, containerd          |          | trustd     (certificates)    |
 |                              |          | containerd, kubelet, etcd    |
 | state: files you edit        |          | state: one machine config    |
 +------------------------------+          +------------------------------+
   you log in and change files               you send a config or an API call
```

The machine configuration is the full description of a node. Talos makes the node agree with this
configuration. Stage [02](../02-machine-config/README.md) is about the machine configuration.

### Components of a node

| Component | Function |
|-----------|----------|
| `machined` | PID 1. It runs the controllers that make the node agree with the configuration. |
| `apid` | The Talos API gateway on TCP port 50000. It sends requests to the local `machined` or to other nodes. |
| `trustd` | Control plane nodes only. Gives certificates to the other nodes (TCP port 50001). |
| `containerd` | Runs the system containers (`apid`, `trustd`, `etcd`, ...). |
| `cri` | A second containerd instance for Kubernetes pods. |
| `sandboxd` | New in 1.14. Holds the namespaces in which `cri`, the kubelet and all pods run (workload isolation). |
| `etcd` | Control plane nodes only. The Kubernetes database. |
| `kubelet` | The Kubernetes node agent. |

### Endpoints and nodes

`talosctl` sends each request to an **endpoint**. The endpoint is the `apid` of a control plane node. The
endpoint `apid` sends the request on to the **nodes** that you select with `-n`. Thus, you can operate all
nodes through one address.

```
 talosctl -n 10.5.1.3 services
     |
     |  mTLS, TCP 50000
     v
 endpoint: apid on basic-controlplane-1  ----proxy---->  apid on basic-worker-1 (10.5.1.3)
                                                             |
                                                             v
                                                          machined: list of services
```

The `talosconfig` file has the endpoints, the default nodes and a client certificate:

```yaml
context: basic
contexts:
    basic:
        endpoints:
            - 127.0.0.1:41234       # apid of the control plane node (port on the host)
        nodes:
            - 10.5.1.2              # default for -n
        ca: <cluster CA>
        crt: <client certificate, role os:admin>
        key: <client key>
```

- Without `-n`, `talosctl` uses `nodes` from the file. The `up` task sets it to the control plane node.
- With `-n 10.5.1.2,10.5.1.3`, one command goes to two nodes. Each output line starts with the node.
- The certificate gives the role `os:admin`. Stage [09](../09-secure/README.md) makes certificates with fewer
  rights.

### Talos nodes in Docker

The Docker provisioner runs each node as a privileged container from the image `ghcr.io/siderolabs/talos`.
All containers connect to one Docker bridge network. The network has the name of the cluster.

```
 host
 +-----------------------------------------------------------------------+
 |  127.0.0.1:<port A> --> 50000 (Talos API)  of basic-controlplane-1    |
 |  127.0.0.1:<port B> -->  6443 (Kubernetes) of basic-controlplane-1    |
 |                                                                       |
 |  docker network "basic" 10.5.1.0/24, gateway 10.5.1.1                 |
 |  ------+-----------------------+-----------------------+----------    |
 |        |                       |                       |              |
 |  +-----+--------------+  +-----+--------------+  +-----+-----------+  |
 |  | basic-             |  | basic-worker-1     |  | basic-worker-2  |  |
 |  | controlplane-1     |  | 10.5.1.3           |  | 10.5.1.4        |  |
 |  | 10.5.1.2           |  | kubelet, cri       |  | kubelet, cri    |  |
 |  | etcd, apiserver,   |  |                    |  |                 |  |
 |  | trustd, kubelet    |  |                    |  |                 |  |
 |  +--------------------+  +--------------------+  +-----------------+  |
 +-----------------------------------------------------------------------+
```

A container is not a full machine. Thus, these functions are not available in Docker: install to a disk,
`upgrade`, `reset`, disk encryption and the boot loader. The QEMU stages (05 to 09) use virtual machines for
these functions. The Docker provisioner can make only one control plane node.

### Resources and controllers

`machined` keeps all state as typed **resources** (the COSI library: Common Operating System Interface).
**Controllers** read resources and write other resources. For example:

```
 MachineConfig ---> controller ---> AddressSpec ---> controller ---> AddressStatus
 (your config)                      (wanted)                         (what the kernel has)
```

`talosctl get <type>` shows resources. `talosctl get rd` (resource definitions) lists all types. Many
`talosctl` commands are short forms of `talosctl get`.

### Bootstrap

A new cluster has no etcd. One control plane node must start etcd as a new cluster. This is the *bootstrap*
(`talosctl bootstrap`). You do it one time for each cluster. `talosctl cluster create` does it for you.
Stage [05](../05-install/README.md) does it by hand.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `basic` |
| Provisioner | Docker |
| Nodes | `basic-controlplane-1` (10.5.1.2), `basic-worker-1` (10.5.1.3), `basic-worker-2` (10.5.1.4) |
| Docker network | `basic`, `10.5.1.0/24` |
| Pod subnet | `10.244.0.0/16` (Talos default), one `/24` per node |
| Service subnet | `10.96.0.0/12` (Talos default) |
| CNI | Flannel (Talos default), VXLAN |
| kube-proxy | yes (nftables mode, Talos default) |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=basic`, `SUBNET`, `TALOSCONFIG=build/talosconfig`, `KUBECONFIG=build/kubeconfig`, tasks `up`, `check` and `down`. |

## Procedure

Do the steps in the stage folder (`01-basic/`). See the [top-level README](../README.md) for the toolchain.

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 //:preflight        docker info, Talos version 1.14 or later
       |
 talos_up_docker     talosctl cluster create docker --name basic --subnet 10.5.1.0/24
       |               --workers 2 --image ghcr.io/siderolabs/talos:<version>
       |             (talosconfig to build/talosconfig, kubeconfig to build/kubeconfig)
       |             talosctl config node 10.5.1.2
 mise run check      talosctl health; kubectl get nodes
```

`talosctl cluster create` makes the network and the containers, sends the machine configuration to each node,
does the bootstrap and waits until the cluster is healthy. This takes 1 to 3 minutes. Expected output at the
end (example):

```
PROVISIONER           docker
NAME                  basic
NETWORK NAME          basic
NETWORK CIDR          10.5.1.0/24
NETWORK GATEWAY       10.5.1.1
NETWORK MTU           1500
KUBERNETES ENDPOINT   https://127.0.0.1:38611

NODES:

NAME                   TYPE           IP         CPU    RAM      DISK
basic-controlplane-1   controlplane   10.5.1.2   2.00   2.1 GB   -
basic-worker-1         worker         10.5.1.3   2.00   2.1 GB   -
basic-worker-2         worker         10.5.1.4   2.00   2.1 GB   -
...
NAME                   STATUS   ROLES           ...   INTERNAL-IP   ...   OS-IMAGE           ...
basic-controlplane-1   Ready    control-plane   ...   10.5.1.2      ...   Talos (v1.14.4)    ...
basic-worker-1         Ready    <none>          ...   10.5.1.3      ...   Talos (v1.14.4)    ...
basic-worker-2         Ready    <none>          ...   10.5.1.4      ...   Talos (v1.14.4)    ...
```

### Step 2: Examine the talosconfig

```bash
talosctl config info
```

Expected output (example):

```
Current context:     basic
Nodes:               10.5.1.2
Endpoints:           127.0.0.1:41234
Roles:               os:admin
Certificate expires: 1 year from now (2027-10-21)
```

- `Endpoints` is a port on the host. Docker sends it to port 50000 of `basic-controlplane-1`.
- `Nodes` is the default target. The `up` task set it with `talosctl config node 10.5.1.2`.

Show the containers and the port mappings:

```bash
docker ps --filter label=talos.cluster.name=basic --format '{{.Names}}\t{{.Ports}}'
```

### Step 3: Check the health

```bash
talosctl health
```

`health` runs checks from the client side. Expected output (example, shortened):

```
discovered nodes: ["10.5.1.2" "10.5.1.3" "10.5.1.4"]
waiting for etcd to be healthy: ...
waiting for etcd to be healthy: OK
waiting for etcd members to be consistent across nodes: OK
waiting for etcd members to be control plane nodes: OK
waiting for apid to be ready: OK
waiting for all nodes memory sizes: OK
waiting for all nodes disk sizes: OK
waiting for kubelet to be healthy: OK
waiting for all nodes to finish boot sequence: OK
waiting for all k8s nodes to report: OK
waiting for all control plane static pods to be running: OK
waiting for all control plane components to be ready: OK
waiting for all k8s nodes to report ready: OK
waiting for kube-proxy to report ready: OK
waiting for coredns to report ready: OK
waiting for all k8s nodes to report schedulable: OK
```

The node list comes from the discovery service (see stage [04](../04-kubespan/README.md)).

### Step 4: Examine the services

Show the services of the control plane node (the default node):

```bash
talosctl services
```

Expected output (example):

```
NODE       SERVICE      STATE     HEALTH   LAST CHANGE   LAST EVENT
10.5.1.2   apid         Running   OK       3m ago        Health check successful
10.5.1.2   containerd   Running   OK       3m ago        Health check successful
10.5.1.2   cri          Running   OK       3m ago        Health check successful
10.5.1.2   etcd         Running   OK       3m ago        Health check successful
10.5.1.2   kubelet      Running   OK       3m ago        Health check successful
10.5.1.2   machined     Running   OK       3m ago        Health check successful
10.5.1.2   sandboxd     Running   OK       3m ago        Health check successful
10.5.1.2   trustd       Running   OK       3m ago        Health check successful
```

Show the services of a worker. A worker has no `etcd` and no `trustd`:

```bash
talosctl -n 10.5.1.3 services
```

Show the log of a service and the kernel log:

```bash
talosctl logs etcd | tail -5
talosctl -n 10.5.1.3 logs kubelet | tail -5
talosctl dmesg | tail -5
```

### Step 5: Examine the containers

Talos has two containerd namespaces. The `system` namespace has the Talos services. The `cri` namespace has
the Kubernetes pods.

```bash
talosctl containers
talosctl containers --namespace cri
```

Expected output of the first command (example):

```
NODE       NAMESPACE   ID       IMAGE                                        PID    STATUS
10.5.1.2   system      apid     ghcr.io/siderolabs/apid:v1.14.4              1234   RUNNING
10.5.1.2   system      trustd   ghcr.io/siderolabs/trustd:v1.14.4            1301   RUNNING
```

In the `cri` namespace you see `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` (static pods),
`kube-proxy`, `kube-flannel` and `coredns`.

### Step 6: Examine the resources

Show the cluster members. The discovery service gives this list:

```bash
talosctl get members
```

Expected output (example):

```
NODE       NAMESPACE   TYPE     ID                     VERSION   HOSTNAME               MACHINE TYPE   OS                ADDRESSES
10.5.1.2   cluster     Member   basic-controlplane-1   1         basic-controlplane-1   controlplane   Talos (v1.14.4)   ["10.5.1.2"]
10.5.1.2   cluster     Member   basic-worker-1         1         basic-worker-1         worker         Talos (v1.14.4)   ["10.5.1.3"]
10.5.1.2   cluster     Member   basic-worker-2         1         basic-worker-2         worker         Talos (v1.14.4)   ["10.5.1.4"]
```

Show the network addresses and routes of a worker:

```bash
talosctl -n 10.5.1.3 get addresses
talosctl -n 10.5.1.3 get routes
```

Count the resource types:

```bash
talosctl get rd | wc -l
```

The result is more than 200. Each type is a small part of the node state.

### Step 7: Open the dashboard

```bash
talosctl dashboard -n 10.5.1.2,10.5.1.3,10.5.1.4
```

The dashboard shows CPU, memory, processes and the log of each node. Use the left and right arrow keys to change
the node. Press `q` to stop.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Try to get a shell

1. Try to start a shell in the control plane container:

   ```bash
   docker exec -it basic-controlplane-1 /bin/sh
   ```

   Expected output:

   ```
   OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
   ```

   The Talos image has no shell. There is nothing to log in to.

2. Read files through the API instead. `ls` and `read` work on all nodes:

   ```bash
   talosctl ls /var/lib
   talosctl read /etc/os-release
   ```

   Expected output of the second command (example):

   ```
   NAME="Talos"
   ID=talos
   VERSION_ID=v1.14.4
   PRETTY_NAME="Talos (v1.14.4)"
   ...
   ```

### Experiment 2: Send one command to many nodes

1. Show the version of all nodes with one command:

   ```bash
   talosctl -n 10.5.1.2,10.5.1.3,10.5.1.4 version --short
   ```

   The endpoint `apid` sends the request to the three nodes. Each output block starts with `NODE:`.

2. Show the machine type of all nodes. Each line starts with the node:

   ```bash
   talosctl -n 10.5.1.2,10.5.1.3,10.5.1.4 get machinetype
   ```

   Expected output (example):

   ```
   NODE       NAMESPACE   TYPE          ID             VERSION   TYPE
   10.5.1.2   config      MachineType   machine-type   1         controlplane
   10.5.1.3   config      MachineType   machine-type   1         worker
   10.5.1.4   config      MachineType   machine-type   1         worker
   ```

3. Send a request to a worker as endpoint. On Linux, the host can reach the container addresses on the
   Docker bridge:

   ```bash
   talosctl -e 10.5.1.3 -n 10.5.1.3 get machinetype
   ```

   The worker `apid` answers directly. Thus, any node can be an endpoint. Use control plane nodes as endpoints,
   because only they can send requests on to all other nodes.

### Experiment 3: Watch a resource change

1. In a second terminal (`mise activate` makes the stage environment available there too), watch the
   Kubernetes node status resource:

   ```bash
   talosctl -n 10.5.1.3 get nodestatus --watch
   ```

2. In the first terminal, cordon the worker:

   ```bash
   kubectl cordon basic-worker-1
   ```

   The watch shows a new version of the resource with `UNSCHEDULABLE true` (example):

   ```
   NODE       *   NAMESPACE   TYPE         ID               VERSION   READY   UNSCHEDULABLE
   10.5.1.3   +   k8s         NodeStatus   basic-worker-1   2         true    false
   10.5.1.3       k8s         NodeStatus   basic-worker-1   3         true    true
   ```

3. Uncordon the worker and stop the watch with `Ctrl+C`:

   ```bash
   kubectl uncordon basic-worker-1
   ```

### Experiment 4: Find a resource type

1. Show the definition of the `Members` resource. The definition has the aliases that `talosctl get` accepts:

   ```bash
   talosctl get rd members.cluster.talos.dev -o yaml
   ```

2. Show all resource types in the `network` namespace:

   ```bash
   talosctl get rd -o json | jq -r 'select(.spec.defaultNamespace == "network") | .spec.aliases[0]' | sort
   ```

   Use the same method to find the resource for a question. For example, `get hostnamestatus` shows the host
   name and `get resolvers` shows the DNS servers.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `talosctl` shows `error reading config: ... no such file`. | The stage environment is not active. `TALOSCONFIG` is not set. | Do `eval "$(mise activate bash)"`, or use `mise x -- talosctl ...` in the stage folder. |
| `cluster create` fails, `network with name basic already exists`. | A cluster with this name exists from an earlier run. | Do `mise run down` first. |
| Flannel pods fail with `Failed to check br_netfilter`. | The host kernel has no `br_netfilter` module loaded. | `sudo modprobe br_netfilter`. |
| `talosctl` shows `rpc error: code = Unavailable` for `-n 10.5.1.x`. | The node is not ready, or the address is wrong. | `talosctl get members` shows the addresses. Wait for `talosctl health`. |
| The `upgrade` or `reset` command fails, "not supported". | The node is a container. | Use the QEMU stages (05 to 09). |

## Clean up

```bash
mise run down
```

This deletes the containers, the Docker network `basic` and the cluster state in `build/state`. The files
`build/talosconfig` and `build/kubeconfig` stay. The next `up` task replaces them.

## References

- Talos in Docker: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/docker
- Architecture and components: https://docs.siderolabs.com/talos/v1.14/learn-more/architecture ,
  https://docs.siderolabs.com/talos/v1.14/learn-more/components
- talosctl, endpoints and nodes: https://docs.siderolabs.com/talos/v1.14/learn-more/talosctl
- Controllers and resources: https://docs.siderolabs.com/talos/v1.14/learn-more/controllers-resources
- Dashboard: https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/interactive-dashboard
- CLI reference: https://docs.siderolabs.com/talos/v1.14/reference/cli
