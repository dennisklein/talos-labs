# 09 – Secure: Secure Boot, TPM encryption, API roles and the ingress firewall

## Purpose

This stage hardens a cluster in four layers: a boot chain that the firmware verifies, system disks that only
this machine in this boot state can open, API clients with the least necessary rights, and a host firewall.

When you complete this stage, you know:

- How UEFI Secure Boot verifies systemd-boot and the Talos UKI, and how the keys get into the firmware.
- How Talos seals the disk keys in the TPM and binds them to the boot state (PCR 7 and PCR 11).
- How to make `talosconfig` files with the roles `os:reader`, `os:operator` and `os:etcd:backup`.
- How the ingress firewall (`NetworkDefaultActionConfig`, `NetworkRuleConfig`) works, and why you apply it
  in `try` mode.
- How `talosctl` forwards requests through its endpoint, and why this matters for firewall rules.

## Concepts

### Trusted boot chain

```
 UEFI firmware (Secure Boot on, Sidero Labs key in db)
    | verifies the signature
    v
 systemd-boot (signed)
    | verifies the signature
    v
 Talos UKI (signed): kernel + initramfs + kernel command line in one file
    | the firmware and systemd-boot measure each step into TPM PCRs
    v
 Talos asks the TPM for the disk key ----> TPM unseals the key only if
    |                                        PCR 7  = same Secure Boot state and keys, and
    v                                        PCR 11 = UKI measurements that match a policy signed by Sidero Labs
 STATE and EPHEMERAL (LUKS2) open
```

- The kernel command line is part of the signed UKI. You cannot change it with the machine configuration.
- The firmware of a VM starts in *setup mode* (no keys). The Talos ISO enrolls the Sidero Labs keys at the
  first boot. On bare metal, you enroll the keys from the boot menu.
- For an upgrade, use the installer image `metal-installer-secureboot`. It contains signed UKIs.

### TPM disk encryption

The TPM generates no key that leaves it. Talos makes a random disk key, *seals* it with the TPM and stores
the sealed key in the LUKS2 header. Only the same TPM with the same PCR values can unseal it. Thus:

| Change | Result |
|--------|--------|
| Normal reboot, upgrade to a signed UKI | The disks open. |
| The disk moves to another machine | The disks do not open (different TPM). |
| Secure Boot off, or different keys in the firmware | The disks do not open (PCR 7 changes). |
| A UKI that is not signed by the key of the PCR policy | The disks do not open (PCR 11 policy). |

### API roles

Talos authorizes clients by the roles in the client certificate (field *organization*):

| Role | Permits |
|------|---------|
| `os:admin` | All API calls. |
| `os:operator` | Everything of `os:reader`, plus reboot, shutdown, service restart, etcd snapshot and alarms, image pull. |
| `os:reader` | Read non-sensitive resources, list files, logs, service status. Not: file content, machine configuration, secrets. |
| `os:etcd:backup` | etcd snapshot and etcd status. |

`talosctl config new --roles ...` asks a node (with an `os:admin` client) to sign a new client certificate.

### Request forwarding

`talosctl` connects to an *endpoint*. If the *node* is a different machine, apid on the endpoint forwards the
request to apid on the node:

```
 talosctl (host 10.5.9.1) --(1)--> apid on 10.5.9.2 (endpoint) --(2)--> apid on 10.5.9.3 (node)
```

A firewall rule for port 50000 on the node must allow connection (2), from the endpoint. This is the trap of
experiment 1.

### Ingress firewall

`NetworkDefaultActionConfig` sets the default for incoming traffic to the host: `accept` (default) or
`block`. Each `NetworkRuleConfig` allows (with `block`) a port and protocol from a list of subnets. Always
allowed: the links `lo`, `kubespan` and `siderolink`, established connections, ICMP (rate limited) and
traffic between the pod and service networks. The firewall does not filter traffic between pods; use network
policies for that.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `secure` |
| Provisioner | QEMU, preset `iso-secureboot` (Secure Boot firmware, software TPM 2.0 with `swtpm`) |
| Nodes | `secure-controlplane-1` (10.5.9.2), `secure-worker-1` (10.5.9.3) |
| Network | bridge, `10.5.9.0/24`, host and load balancer `10.5.9.1` |
| System disk encryption | STATE and EPHEMERAL, LUKS2, TPM key |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=secure`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `up`, `check` and `down`. |
| `examples/firewall-controlplane.yaml` | Firewall for the control plane node (recommended rules, Flannel VXLAN). |
| `examples/firewall-worker.yaml` | Firewall for the worker. The kubelet port is closed for the host. |
| `examples/firewall-lockout.yaml` | A wrong rule: apid only from the host. For experiment 1, in `try` mode only. |

## Procedure

Do the steps in the stage folder (`09-secure/`). The host needs `swtpm` and an OVMF firmware with Secure Boot
support (see the [main README](../README.md#host-requirements)).

### Step 1: Start the lab

```bash
mise run up
```

The task downloads the Secure Boot ISO from the Image Factory. Expected output of the security state at the
end (example):

```
NODE       NAMESPACE   TYPE            ID              VERSION   SECUREBOOT   UKISIGNINGKEYFINGERPRINT   PCRSIGNINGKEYFINGERPRINT   SELINUXSTATE   MODULESIGNATUREENFORCED
10.5.9.2   runtime     SecurityState   securitystate   1         true         2ba4...                    c1d0...                    permissive     true
10.5.9.3   runtime     SecurityState   securitystate   1         true         2ba4...                    c1d0...                    permissive     true
```

### Step 2: Examine the boot chain

1. Show the details of the security state:

   ```bash
   talosctl get securitystate -o yaml | yq .spec
   ```

   - `secureBoot: true`: the firmware verified the boot chain.
   - `bootedWithUKI: true`: Talos runs from a UKI.
   - `moduleSignatureEnforced: true`: the kernel loads only signed modules.

2. Show the installer image in the configuration:

   ```bash
   talosctl get machineconfig v1alpha1 -o jsonpath='{.spec}' | yq 'select(.kind == "UnattendedInstallConfig") | .installer.image'
   ```

   The image name is `factory.talos.dev/metal-installer-secureboot/...`.

### Step 3: Examine the disk encryption

```bash
talosctl get discoveredvolumes | grep -E 'TYPE|luks'
talosctl get volumestatus STATE -o yaml | yq '.spec | {"phase": .phase, "encryptionProvider": .encryptionProvider, "configuredEncryptionKeys": .configuredEncryptionKeys, "tpmEncryptionOptions": .tpmEncryptionOptions}'
talosctl get volumestatus EPHEMERAL -o yaml | yq '.spec.encryptionProvider'
```

- STATE and EPHEMERAL show the file system type `luks` on the disk.
- The encryption provider is `luks2`. The key slot uses the TPM.

### Step 4: Make clients with less rights

1. Show the role of your current client:

   ```bash
   talosctl config info
   ```

   Expected output (part): `Roles: os:admin`.

2. Make three new client configurations. Each certificate is valid for one hour:

   ```bash
   talosctl config new build/reader.talosconfig   --roles os:reader      --crt-ttl 1h
   talosctl config new build/operator.talosconfig --roles os:operator    --crt-ttl 1h
   talosctl config new build/backup.talosconfig   --roles os:etcd:backup --crt-ttl 1h
   talosctl --talosconfig build/reader.talosconfig config info
   ```

3. Try the reader:

   ```bash
   R="talosctl --talosconfig build/reader.talosconfig"
   $R get members                                  # works
   $R list /etc                                    # works
   $R read /etc/os-release                         # fails: PermissionDenied
   $R get machineconfig                            # fails: the configuration is sensitive
   $R -n 10.5.9.3 reboot                           # fails: PermissionDenied
   ```

4. Try the operator and the backup client:

   ```bash
   talosctl --talosconfig build/operator.talosconfig -n 10.5.9.3 service kubelet restart      # works
   talosctl --talosconfig build/operator.talosconfig read /etc/os-release                     # fails
   talosctl --talosconfig build/backup.talosconfig etcd snapshot build/etcd.snapshot           # works
   talosctl --talosconfig build/backup.talosconfig get members                                # fails
   ```

### Step 5: Enable the firewall on the control plane node

1. Show the rules:

   ```bash
   cat examples/firewall-controlplane.yaml
   ```

2. Apply them in `try` mode for 3 minutes:

   ```bash
   talosctl -n 10.5.9.2 patch mc --mode try --timeout 3m -p @examples/firewall-controlplane.yaml
   ```

3. In the 3 minutes, check that the cluster works:

   ```bash
   talosctl -n 10.5.9.2 version
   kubectl get nodes
   kubectl -n kube-system logs -l k8s-app=kube-dns --tail 1
   talosctl -n 10.5.9.2 get nftableschain ingress -o yaml | yq .spec.rules
   ```

4. If all commands work, apply the rules permanently:

   ```bash
   talosctl -n 10.5.9.2 patch mc -p @examples/firewall-controlplane.yaml
   ```

   If the `try` timeout ended before this step, the patch applies the same rules again. That is correct.

## Experiments

Do the experiments after the procedure, in the sequence below.

### Experiment 1: Lock yourself out, safely

1. Apply the wrong rule on the worker in `try` mode for 1 minute:

   ```bash
   cat examples/firewall-lockout.yaml
   talosctl -n 10.5.9.3 patch mc --mode try --timeout 1m -p @examples/firewall-lockout.yaml
   ```

2. Try the worker through the endpoint (the control plane node):

   ```bash
   talosctl -n 10.5.9.3 version
   ```

   The command fails after a timeout: the worker blocks the forwarded request from 10.5.9.2.

3. Try the worker directly (the worker is the endpoint):

   ```bash
   talosctl -e 10.5.9.3 -n 10.5.9.3 version
   ```

   The command works: the request comes from the host, 10.5.9.1.

4. Wait 1 minute. Talos reverts the change. Step 2 works again.

### Experiment 2: Close the kubelet port for the host

1. Before the change, connect to the kubelet port of the worker from the host:

   ```bash
   nc -zv -w 2 10.5.9.3 10250
   ```

   Expected output: `Connection to 10.5.9.3 10250 port [tcp/*] succeeded!`

2. Apply the worker rules in `try` mode, then check:

   ```bash
   talosctl -n 10.5.9.3 patch mc --mode try --timeout 3m -p @examples/firewall-worker.yaml
   nc -zv -w 2 10.5.9.3 10250                                   # times out
   kubectl run probe --image=busybox:1.37 --restart=Never --overrides='{"spec":{"nodeName":"secure-worker-1"}}' -- sh -c 'echo hello'
   kubectl logs probe                                           # works: the API server (10.5.9.2) connects to the kubelet
   kubectl delete pod probe
   ```

   The host cannot reach the kubelet, but the API server can.

3. Wait 3 minutes for the revert, or apply the rules permanently:

   ```bash
   talosctl -n 10.5.9.3 patch mc -p @examples/firewall-worker.yaml
   ```

### Experiment 3: A reboot with the TPM

1. Reboot the worker and check that STATE and EPHEMERAL open without user input:

   ```bash
   talosctl -n 10.5.9.3 reboot
   talosctl -n 10.5.9.3 get volumestatuses | grep -E 'NODE|STATE|EPHEMERAL'
   ```

2. Read the boot log of the worker for the TPM unlock:

   ```bash
   talosctl -n 10.5.9.3 dmesg | grep -i -E 'tpm|luks|unseal' | head
   ```

### Experiment 4: An expired client certificate

1. Make a reader certificate that is valid for one minute:

   ```bash
   talosctl config new build/short.talosconfig --roles os:reader --crt-ttl 1m
   talosctl --talosconfig build/short.talosconfig get members
   ```

2. Wait two minutes and try again:

   ```bash
   talosctl --talosconfig build/short.talosconfig get members
   ```

   The command fails with a TLS error: the certificate expired. Short certificates limit the damage of a lost
   `talosconfig` file.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `cluster create` fails: `swtpm` not found. | The software TPM is not installed. | Install `swtpm` (Debian, Ubuntu: `swtpm swtpm-tools`). |
| `cluster create` fails: no Secure Boot firmware. | No OVMF file with Secure Boot support. | Install `ovmf` (Debian, Ubuntu) or `edk2-ovmf` (Fedora). The file is `OVMF_CODE_4M.secboot.fd` or similar. |
| The VM stops with `Access Denied` or `Security Violation`. | The firmware has keys that do not match, or setup mode was off. | `mise run down` deletes the firmware variables. Start again. |
| Step 2 of experiment 1 never works again. | The patch was applied without `--mode try`. | Use the direct path to the worker: `talosctl -e 10.5.9.3 -n 10.5.9.3 edit mc`, and correct the subnet of `apid-ingress`. |
| `config new` fails with `PermissionDenied`. | The current client is not `os:admin`. | Use `build/talosconfig`. |
| Pods on different nodes cannot connect after the firewall change. | VXLAN (UDP 4789) is blocked. | Keep the rule `cni-vxlan`. With Cilium, the port is 8472. |

Note: `patch mc` merges lists. A second `NetworkRuleConfig` with the same name adds its subnets to the first.
To remove a wrong rule, delete the document (`$patch: delete`) and add it again, as in stage 02.

## Clean up

```bash
mise run down
```

## References

- Secure Boot: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/secureboot
- Disk encryption: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption
- RBAC: https://docs.siderolabs.com/talos/v1.14/security/rbac
- Ingress firewall: https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall
- `NetworkRuleConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/networkruleconfig
- Trusted boot (background): https://0pointer.net/blog/brave-new-trusted-boot-world.html
