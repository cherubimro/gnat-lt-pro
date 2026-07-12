# Running the diode on the Intel machines (kernel bypass)

A runbook for two physical machines with Intel NICs, doing **real DPDK kernel bypass** —
the NIC is taken from the kernel and driven from userspace.

- *Why* you might not want this at all (it puts DPDK inside the trusted computing base):
  [`docs/ASSURANCE.md` §5.1](docs/ASSURANCE.md).
- *What* the commands below are actually doing, and what to do when they fail:
  [`KERNEL-BYPASS.TXT`](KERNEL-BYPASS.TXT).

This page is just the steps.

---

## 0. Checklist — none of these are optional

| | |
|---|---|
| **Two machines on one L2 segment** | Direct cable, or the same switch/VLAN. **Wi-Fi will not work** (802.11 drops our EtherType `0x88B6`), and neither will cloud networks. |
| **A *spare* Intel NIC on each** | A NIC bound to `vfio-pci` **vanishes from the kernel** — no IP, no SSH. Keep a *different* interface for your login. |
| **An IOMMU** | `intel_iommu=on iommu=pt` on the kernel cmdline + VT-d enabled in the BIOS. Verify: `ls /sys/kernel/iommu_groups/` must be non-empty. |
| **Root, for setup only** | Binding the NIC and allocating hugepages need root. The daemon itself can run unprivileged afterwards (§6). |
| **The same SEED on both machines** | It selects the fountain-code sampling. Mismatch ⇒ garbage, caught by the checksum gate and marked `.corrupt`. |

Supported cards:

| Intel card | PMD |
|---|---|
| 82599, X520, X540, X550 | `ixgbe` — most Intel 10G |
| X710, XL710, X722 | `i40e` |
| E810 | `ice` |
| I210, I350, igb | `e1000` |

---

## 1. Get the code onto both machines

**Option A — copy the pre-built binaries (no toolchain needed).** DPDK is linked *statically* into
our binaries, so a machine of the same distro/arch needs neither GNAT nor DPDK:

```sh
# on the build box, once:
./tools/dpdk-build-nic.sh
DPDK_PREFIX="$PWD/../dpdk/deps/dpdk-install-nic" WITH_DPDK=yes ./tools/build.sh

# then to each Intel machine:
rsync -a bin/ tools/ intel:lt-diode/
```

`tools/pmd-ids.txt` travels with them, which is why the scripts can still identify your card
without the DPDK source tree.

**Option B — build on each machine.** Needs GNAT 14.2 + gprbuild. On Debian/Ubuntu, DPDK comes from
the distro and carries every PMD already:

```sh
sudo apt install build-essential pkg-config libdpdk-dev dpdk
unset DPDK_PREFIX          # so pkg-config finds the system libdpdk.pc
WITH_DPDK=yes ./tools/build.sh
```

---

## 2. Look before you leap

On **each** machine (no root, changes nothing):

```sh
./tools/bypass.sh doctor
```

You are looking for a line in the card table like:

```
PCI            IFACE     DRIVER    IOMMU  VENDOR:DEV  DPDK PMD
0000:02:00.0   eno1      e1000e    12     8086:15fb   e1000     <-- DO NOT BIND (default route / SSH)
0000:03:00.0   eno2      ixgbe     17     8086:10fb   ixgbe
```

**Bind `eno2`.** It has a real PMD and no `DO NOT BIND` marker.

Stop and fix things if you see:

- **`DPDK PMD` is `?`** — DPDK has no driver for that card. Bypass with it is impossible. Use the
  other card.
- **`no IOMMU`** — enable VT-d in the BIOS and add `intel_iommu=on iommu=pt` to the kernel cmdline,
  then reboot.
- **`no VFIO` in the binaries** — `bypass.sh` will rebuild them for you in step 3; nothing to do.

---

## 3. Machine A — the receiver

```sh
sudo ./tools/bypass.sh receiver eno2
```

It builds what is missing, verifies VFIO and `ixgbe` really landed in the binary, allocates
hugepages, binds `eno2` to `vfio-pci`, and starts listening on the bypassed port:

```
=== 6/6  receiver on the bypassed port ===
  spool  : /var/spool/lt-diode
  seed   : 1234   <-- the sender MUST use the same
  EAL    : -l 0 -a 0000:03:00.0 --file-prefix=ltd12345

INFO [rs] listening on DPDK port 0 (kernel bypass, EtherType 0x88B6)  spool /var/spool/lt-diode ...
```

`eno2` is now **gone** from `ip link`. That is correct — that is what bypass means.

Leave it running. `Ctrl-C` stops it; the NIC stays bound so the next run is instant.

---

## 4. Machine B — the sender

```sh
sudo ./tools/bypass.sh sender eno2 /path/to/bigfile
```

Same six steps, then it blasts the file across. Destination is **broadcast** by default — a diode
sender need not know who is listening. To unicast at one peer: `DST=aa:bb:cc:dd:ee:ff sudo ./tools/bypass.sh sender ...`

---

## 5. Did it work?

On the receiver, in `/var/spool/lt-diode/`:

| file | meaning |
|---|---|
| `bigfile` | the decoded data |
| `bigfile.finished` | **checksum verified** — this is the success marker |
| `bigfile.corrupt` | decode or checksum failed; `verify.log` has a `reason=` |
| `verify.log` | one line per transfer: `verdict=ok` or `reason=decode/checksum/size/...` |

```sh
ls -la /var/spool/lt-diode/
tail /var/spool/lt-diode/verify.log
md5sum /path/to/bigfile                       # on the sender
md5sum /var/spool/lt-diode/bigfile            # on the receiver — must match
```

**A `.finished` file is never wrong.** The whole-stream checksum is computed by the proven core and
gates every transfer, so a fault anywhere — in DPDK, in the PMD, on the wire — yields a detected
`.corrupt`, never a silently bad `.finished`. That property is unchanged by kernel bypass.

---

## 6. Running the daemon without root (optional)

`bypass.sh bind` already chowns `/dev/vfio/<group>` to the user who invoked `sudo`. Two more things
and the daemon needs no privilege at all:

```sh
sudo chmod 777 /dev/hugepages
# /etc/security/limits.conf:
#   yourname   -   memlock   unlimited
```

Then run `./bin/receiver_stream --with-dpdk --eal "-l 0 -a 0000:03:00.0" 0 /var/spool/lt-diode 1234 0`
as yourself.

---

## 7. Giving the NIC back

```sh
sudo ./tools/bypass.sh teardown eno2          # or the PCI address
```

It rebinds the kernel driver it recorded at bind time and brings the interface back up.

---

## 8. When it doesn't work

| Symptom | Cause | Fix |
|---|---|---|
| `no ethdev port available` | The DPDK you linked has no driver for this card | `./tools/dpdk-build-nic.sh`, rebuild. `bypass.sh` step 3 now catches this *before* you get here. |
| `no DPDK PMD matches 0000:xx` | Card genuinely unsupported (e.g. Realtek) | Use the Intel card. |
| `VFIO group is not viable` | Another device in the same IOMMU group is still held by a kernel driver | `./tools/vfio-setup.sh status`; bind the whole group, or move the card to another slot. |
| `Cannot init memory` / hugepage errors | No hugepages, or another DPDK process owns them | `sudo ./tools/vfio-setup.sh hugepages 512`; give each process a distinct `--file-prefix`. |
| `Operation not permitted` on vfio | IOMMU off, or non-root without §6 | `dmesg \| grep -i DMAR`; do §6. |
| Link stays down | Cable / switch port / other end not up | The sender waits 5s then transmits anyway (a diode has no feedback), so frames just go nowhere. |
| Transfers arrive as `.corrupt` | **Almost always a SEED MISMATCH** | Same `SEED=` on both machines. `reason=checksum` = decoded but wrong; `reason=decode` = too few packets arrived. |
| Nothing arrives at all | Wrong segment, or frames not on the wire | From a third box: `sudo tcpdump -i eno1 -e ether proto 0x88b6` |

---

## 9. The one-liner summary

```sh
# machine A                                  # machine B
sudo ./tools/bypass.sh receiver eno2         sudo ./tools/bypass.sh sender eno2 bigfile
```

Same `SEED`. Same L2 segment. A spare Intel NIC on each. Everything else the script handles.
