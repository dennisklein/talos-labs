# 08 – Storage: volumes, extra disks and encryption

## Purpose

Talos manages all disks with configuration documents: the system volumes (STATE, EPHEMERAL), user volumes for
workloads and raw partitions. This stage gives the workers two extra disks and makes each kind of volume. A
pod then stores data on a local PersistentVolume.

When you complete this stage, you know:

- How Talos discovers disks and volumes, and how a CEL expression selects a disk.
- How to set the size of EPHEMERAL with `VolumeConfig`.
- The three kinds of user volume (`partition`, `directory`, `disk`) and where Talos mounts them.
- How `RawVolumeConfig` makes a partition without a file system.
- How LUKS2 encryption with a node-bound key works, and what `lockToState` does.
- How to give a user volume to a pod as a local PersistentVolume.
- What happens to the data when you remove a volume from the configuration.

## Concepts

### From disk to mount

```
 disk                       volume document                      partition and mount
 vda 10 GiB (system) <----- VolumeConfig EPHEMERAL          --->  vda4 EPHEMERAL    -> /var
                     <----- UserVolumeConfig scratch        --->  vda5 u-scratch    -> /var/mnt/scratch
 vdb  6 GiB          <----- UserVolumeConfig local-data     --->  vdb1 u-local-data -> /var/mnt/local-data
                     <----- UserVolumeConfig secret (LUKS2) --->  vdb2 u-secret     -> /var/mnt/secret
 vdc  4 GiB          <----- RawVolumeConfig raw-data        --->  vdc1 r-raw-data   (no file system, no mount)
 (EPHEMERAL)         <----- UserVolumeConfig cache (dir)    --->  /var/mnt/cache (directory on /var)
```

The volume controllers do these steps for each volume:

1. **Locate.** Find an existing partition with the label (`u-<name>`, `r-<name>`). If one exists, use it.
2. **Provision.** Else, select a disk with `provisioning.diskSelector.match` and make a partition with a size
   between `minSize` and `maxSize`.
3. **Format and mount.** Make the file system (XFS by default) if the partition is empty, and mount it.

The phases show in `talosctl get volumestatuses`: `waiting`, `located`, `provisioned`, `prepared`, `ready`
(or `missing` and `failed` if a step does not succeed).

### Disk selection with CEL

`diskSelector.match` is a CEL expression that Talos evaluates for each disk. Examples:

| Expression | Selects |
|------------|---------|
| `disk.dev_path == "/dev/vdb"` | The disk with that path. |
| `system_disk` | The disk with the Talos install. |
| `!system_disk && disk.size > 5u * GiB` | A disk without Talos with more than 5 GiB. |
| `disk.transport == "nvme" && !disk.rotational` | An NVMe SSD. |

The fields are the fields of `talosctl get disks -o yaml`.

### Kinds of user volumes

| `volumeType` | Storage | Size limit | Use |
|--------------|---------|------------|-----|
| `partition` (default) | New partition on the selected disk. | Yes (`minSize`, `maxSize`). | Most workloads. |
| `directory` | Directory on EPHEMERAL. | No. Shares the space of `/var`. | Small caches, no extra disk. |
| `disk` | The complete selected disk. | The disk size. | Software that needs a full disk. |

All user volumes are mounted at `/var/mnt/<name>`. Talos propagates the mount into the kubelet, so pods can
use `hostPath` or a `local` PersistentVolume.

### Encryption

Talos encrypts volumes with LUKS2. A key slot gets its key from one source:

| Key source | Key |
|------------|-----|
| `static` | A passphrase in the configuration. |
| `nodeID` | Derived from the node ID (unique per machine). |
| `tpm` | Sealed in the TPM; Talos can bind it to Secure Boot (stage 09). |
| `kms` | From a key management server over the network. |

With `lockToState: true`, Talos also binds the key to the STATE partition. After a reset (new STATE) or
when you move the disk to another machine, Talos cannot open the volume.

### Remove a volume

If you remove a volume document, Talos unmounts the volume. The partition and its data stay on the disk. If
you add the document again, Talos locates the partition by its label and mounts it with the old data. To
delete the data, use `talosctl wipe disk <partition> --drop-partition`.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `storage` |
| Provisioner | QEMU, preset `iso` |
| Nodes | `storage-controlplane-1` (10.5.8.2), `storage-worker-1` (10.5.8.3), `storage-worker-2` (10.5.8.4) |
| Network | bridge, `10.5.8.0/24`, gateway and load balancer `10.5.8.1` |
| Disks of each worker | `vda` 10 GiB (system, EPHEMERAL limited to 5 GiB), `vdb` 6 GiB, `vdc` 4 GiB |

## Files

| File | Content |
|------|---------|
| `mise.toml` | `CLUSTER=storage`, `SUBNET`, `TALOSCONFIG`, `KUBECONFIG`, tasks `up`, `check` and `down`. |
| `patches/worker/ephemeral.yaml` | `VolumeConfig` EPHEMERAL with `maxSize: 5GiB` on the workers. |
| `examples/user-volume.yaml` | User volume `local-data`, 1 to 3 GiB on `vdb`. |
| `examples/user-volume-system-disk.yaml` | User volume `scratch`, 1 to 2 GiB on the system disk. |
| `examples/user-volume-directory.yaml` | User volume `cache` as a directory on EPHEMERAL. |
| `examples/user-volume-encrypted.yaml` | User volume `secret`, 1 GiB on `vdb`, LUKS2 with a `nodeID` key. |
| `examples/raw-volume.yaml` | Raw volume `raw-data`, 1 GiB on `vdc`. |
| `examples/user-volume-delete.yaml` | Removes the document of `local-data`. |
| `examples/local-pv.yaml` | StorageClass, local PersistentVolume on `/var/mnt/local-data`, PVC and pod. |

## Procedure

Do the steps in the stage folder (`08-storage/`). All steps use the worker `storage-worker-1` (10.5.8.3).

### Step 1: Start the lab

```bash
mise run up
```

### Step 2: Examine the disks and the system volumes

1. Show the disks:

   ```bash
   talosctl -n 10.5.8.3 get disks
   ```

   Expected output:

   ```
   NODE       NAMESPACE   TYPE   ID      VERSION   SIZE     READ ONLY   TRANSPORT   ROTATIONAL   WWID   MODEL          SERIAL
   10.5.8.3   runtime     Disk   loop0   2         4.1 kB   true
   10.5.8.3   runtime     Disk   loop1   2         94 MB    true
   10.5.8.3   runtime     Disk   sr0     2         364 MB   true        sata        true                QEMU DVD-ROM
   10.5.8.3   runtime     Disk   sr1     2         0 B      true        sata                            QEMU DVD-ROM
   10.5.8.3   runtime     Disk   vda     2         11 GB    false       virtio      true
   10.5.8.3   runtime     Disk   vdb     2         6.4 GB   false       virtio      true
   10.5.8.3   runtime     Disk   vdc     2         4.3 GB   false       virtio      true
   ```

   `vda` is the system disk, `vdb` (6 GiB) and `vdc` (4 GiB) are the extra disks. `sr0` is the Talos ISO,
   `loop1` the squashfs of the running system.

2. Show the details of one disk. These fields are available in CEL expressions:

   ```bash
   talosctl -n 10.5.8.3 get disk vdb -o yaml | yq .spec
   ```

   Expected output (part):

   ```
   dev_path: /dev/vdb
   size: 6442450944
   pretty_size: 6.4 GB
   readonly: false
   cdrom: false
   transport: virtio
   rotational: true
   symlinks:
     - /dev/disk/by-diskseq/12
     - /dev/disk/by-path/pci-0000:00:08.0
     - /dev/disk/by-path/virtio-pci-0000:00:08.0
   ```

   A CEL expression uses the names with the prefix `disk.`, for example `disk.dev_path == "/dev/vdb"` or
   `disk.size > 5u * GiB`.

3. Show the partitions and the system volumes:

   ```bash
   talosctl -n 10.5.8.3 get discoveredvolumes
   talosctl -n 10.5.8.3 get volumestatuses
   ```

   Expected output of `discoveredvolumes` (part):

   ```
   NODE       NAMESPACE   TYPE               ID      VERSION   TYPE        SIZE     DISCOVERED   LABEL       PARTITIONLABEL
   10.5.8.3   runtime     DiscoveredVolume   vda1    1         partition   2.2 GB   vfat         EFI         EFI
   10.5.8.3   runtime     DiscoveredVolume   vda2    1         partition   1.0 MB   talosmeta                META
   10.5.8.3   runtime     DiscoveredVolume   vda3    1         partition   105 MB   xfs          STATE       STATE
   10.5.8.3   runtime     DiscoveredVolume   vda4    1         partition   5.4 GB   xfs          EPHEMERAL   EPHEMERAL
   10.5.8.3   runtime     DiscoveredVolume   vdb     1         disk        6.4 GB
   10.5.8.3   runtime     DiscoveredVolume   vdc     1         disk        4.3 GB
   ```

   EPHEMERAL is 5 GiB (5.4 GB, the patch). The rest of `vda` (about 3 GB) is free. `vdb` and `vdc` have no
   partition table.

### Step 3: Make a user volume on the extra disk

1. Apply the document:

   ```bash
   cat examples/user-volume.yaml
   talosctl -n 10.5.8.3 patch mc -p @examples/user-volume.yaml
   ```

2. Watch the volume. Stop with `Ctrl+C` when the phase is `ready`:

   ```bash
   talosctl -n 10.5.8.3 get volumestatus u-local-data --watch
   ```

   Expected output at the end:

   ```
   NODE       NAMESPACE   TYPE           ID             VERSION   TYPE        PHASE   LOCATION    SIZE
   10.5.8.3   runtime     VolumeStatus   u-local-data   2         partition   ready   /dev/vdb1   3.2 GB
   ```

   The size is `maxSize` (3 GiB), because the disk has enough space.

3. Show the mount:

   ```bash
   talosctl -n 10.5.8.3 get mountstatus u-local-data
   talosctl -n 10.5.8.3 list /var/mnt
   ```

   Expected output of `get mountstatus`:

   ```
   NODE       NAMESPACE   TYPE          ID             VERSION   SOURCE      TARGET                FILESYSTEM   VOLUME
   10.5.8.3   runtime     MountStatus   u-local-data   2         /dev/vdb1   /var/mnt/local-data   xfs          u-local-data
   ```

   No reboot was necessary.

### Step 4: Use the volume in a pod

1. Make the StorageClass, the PersistentVolume, the claim and the pod:

   ```bash
   kubectl apply -f examples/local-pv.yaml
   kubectl wait --for=condition=Ready pod/writer --timeout=2m
   kubectl get pv,pvc
   kubectl get pod writer -o wide
   ```

   The pod runs on `storage-worker-1`: the PersistentVolume has a node affinity. The PV and the claim are
   `Bound`. `kubectl apply` shows a warning that the pod violates the Pod Security level `restricted`. This
   is only a warning: the default level `baseline` permits the pod.

2. Read the file from the host side with the Talos API:

   ```bash
   talosctl -n 10.5.8.3 read /var/mnt/local-data/log.txt
   ```

3. Delete the pod and make it again. The file keeps the old line and gets a new one:

   ```bash
   kubectl delete pod writer
   kubectl apply -f examples/local-pv.yaml
   kubectl wait --for=condition=Ready pod/writer --timeout=2m
   kubectl exec writer -- cat /data/log.txt
   ```

   Expected output (example):

   ```
   Fri Oct 23 09:52:26 UTC 2026
   Fri Oct 23 09:53:00 UTC 2026
   ```

## Experiments

Do the experiments after the procedure, in the sequence below.

### Experiment 1: A user volume on the system disk

```bash
talosctl -n 10.5.8.3 patch mc -p @examples/user-volume-system-disk.yaml
talosctl -n 10.5.8.3 get volumestatus u-scratch
talosctl -n 10.5.8.3 get discoveredvolumes | grep vda
```

The new partition `u-scratch` is `/dev/vda5` (2.1 GB, `maxSize`), after EPHEMERAL. Without the EPHEMERAL
limit, EPHEMERAL takes the full disk and the volume does not become `ready` (no space).

### Experiment 2: A directory volume

```bash
talosctl -n 10.5.8.3 patch mc -p @examples/user-volume-directory.yaml
talosctl -n 10.5.8.3 get volumestatus u-cache
talosctl -n 10.5.8.3 get mountstatus u-cache
```

The type is `directory`, and the mount has no source device (`SOURCE` is empty, `FILESYSTEM` is `none`):
`/var/mnt/cache` is a directory on EPHEMERAL. There is no new partition.

### Experiment 3: An encrypted volume

1. Apply the document:

   ```bash
   cat examples/user-volume-encrypted.yaml
   talosctl -n 10.5.8.3 patch mc -p @examples/user-volume-encrypted.yaml
   talosctl -n 10.5.8.3 get volumestatus u-secret --watch      # stop with Ctrl+C at "ready"
   ```

2. Examine the encryption:

   ```bash
   talosctl -n 10.5.8.3 get volumestatus u-secret -o yaml | yq '.spec | {"location": .location, "mountLocation": .mountLocation, "encryptionProvider": .encryptionProvider, "encryptionFailedSyncs": .encryptionFailedSyncs}'
   talosctl -n 10.5.8.3 get discoveredvolumes | grep -E 'TYPE|luks'
   ```

   Expected output:

   ```
   location: /dev/vdb2
   mountLocation: /dev/dm-0
   encryptionProvider: luks2
   encryptionFailedSyncs: null
   NODE       NAMESPACE   TYPE               ID      VERSION   TYPE        SIZE     DISCOVERED   LABEL   PARTITIONLABEL
   10.5.8.3   runtime     DiscoveredVolume   vdb2    2         partition   1.1 GB   luks                 u-secret
   ```

   - `location` is the partition (`/dev/vdb2`), with the file system type `luks` on the disk.
   - `mountLocation` is the opened device mapper device (`/dev/dm-0`).

3. Reboot the node. Talos opens the volume again without user input, because the key comes from the node:

   ```bash
   talosctl -n 10.5.8.3 reboot
   talosctl -n 10.5.8.3 get volumestatus u-secret
   ```

### Experiment 4: A raw volume

```bash
talosctl -n 10.5.8.3 patch mc -p @examples/raw-volume.yaml
talosctl -n 10.5.8.3 get volumestatus r-raw-data
talosctl -n 10.5.8.3 list /dev/disk/by-partlabel
```

The phase is `ready` (`/dev/vdc1`, 1.1 GB), but there is no mount. The list of `/dev/disk/by-partlabel`
shows `EFI`, `EPHEMERAL`, `META`, `STATE`, `r-raw-data`, `u-local-data`, `u-scratch` and `u-secret`. The link
`r-raw-data` points to the partition. A storage system (for example Ceph or OpenEBS) can use it as a block device.

### Experiment 5: Remove a volume and add it again

1. Delete the pod and the PersistentVolume first. A volume in use must not go away:

   ```bash
   kubectl delete -f examples/local-pv.yaml
   ```

2. Remove the document:

   ```bash
   talosctl -n 10.5.8.3 patch mc -p @examples/user-volume-delete.yaml
   talosctl -n 10.5.8.3 get volumestatus u-local-data
   talosctl -n 10.5.8.3 get discoveredvolumes | grep u-local-data
   ```

   `get volumestatus` fails with `NotFound`: the volume status is gone. The partition is still on `vdb`:

   ```
   NODE       NAMESPACE   TYPE               ID     VERSION   TYPE        SIZE     DISCOVERED   LABEL   PARTITIONLABEL
   10.5.8.3   runtime     DiscoveredVolume   vdb1   1         partition   3.2 GB   xfs                  u-local-data
   ```

3. Add the document again and read the old file:

   ```bash
   talosctl -n 10.5.8.3 patch mc -p @examples/user-volume.yaml
   talosctl -n 10.5.8.3 get volumestatus u-local-data --watch    # stop with Ctrl+C at "ready"
   talosctl -n 10.5.8.3 read /var/mnt/local-data/log.txt
   ```

   The data is still there. Talos located the partition by its label and did not format it.

4. To delete the data, remove the document again and wipe the partition:

   ```bash
   talosctl -n 10.5.8.3 patch mc -p @examples/user-volume-delete.yaml
   talosctl -n 10.5.8.3 wipe disk vdb1 --drop-partition
   ```

   `wipe` prints nothing. After it, `talosctl -n 10.5.8.3 get discoveredvolumes | grep vdb` shows no `vdb1`, and
   `/dev/disk/by-partlabel` has no `u-local-data`. In the test, `vdb1` stayed in the list when `u-secret`
   (experiment 3) was still open on the same disk. A probable cause: the kernel does not read the partition
   table of a disk again while another partition of it is in use.

   If the command fails with `blockdevice "vdb1" is in use by volume "u-local-data"`, the document is still
   in the configuration.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| A volume does not become `ready` (phase `waiting`, `missing` or `failed`). | No disk matches, or the selected disk has no free space for `minSize`. | `talosctl get volumestatus <id> -o yaml` shows the error. Check the expression against `get disks -o yaml`. |
| `u-scratch` does not become `ready`. | EPHEMERAL takes the full system disk. | `patches/worker/ephemeral.yaml` applies only at the install. Make the cluster again: `mise run down && mise run up`. |
| The pod `writer` stays `Pending`. | The PV is bound to `storage-worker-1`, but the user volume is on a different node, or not ready. | `kubectl describe pod writer`. Apply the user volume to `10.5.8.3`. |
| `wipe disk` fails with `blockdevice is in use by volume`. | The volume document is still in the configuration. | Remove the document first (experiment 5, step 2). |
| The encrypted volume does not open after a reset. | `lockToState: true`: the new STATE has a different key. | This is the intended result. Wipe the partition and make the volume again. |

## Clean up

```bash
mise run down
```

## References

- Disk management overview: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/overview
- Disk layout: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/layout
- System volumes: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/system
- User volumes: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user
- Raw volumes: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/raw
- Disk encryption: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption
- `UserVolumeConfig`: https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/uservolumeconfig
- Kubernetes local volumes: https://kubernetes.io/docs/concepts/storage/volumes/#local
