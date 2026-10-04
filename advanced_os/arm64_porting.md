# NVMeVirt ARM64 Porting Notes

## Overview

The original NVMeVirt implementation assumes an x86-64 host. In particular, PCI/MSI interrupt delivery, APIC-based IRQ handling, boot-time memory reservation, and the way PCI BARs are accessed are all built around how x86 Linux works. This design passes `advanced_os/verify_nvmev_x86-64.sh` on x86-64, but the same assumptions do not hold on ARM64 platforms.

The goal of this port was to keep the existing x86-64 behavior while making NVMeVirt work on ARM64 as well: the host should recognize it as a virtual NVMe device, create namespaces on it, and perform real block I/O. The final verification on the ARM64 target covered module build/load, PCI/NVMe discovery, NVMe admin commands, filesystem creation, mount, data integrity, direct I/O, and unload.

## Porting Challenges and Solutions

### 1. Boot-Time Memory Reservation

NVMeVirt uses part of host memory as the backing store of the virtual SSD and as the backing region for its MMIO registers. On x86-64, the natural approach is to exclude that physical address range from System RAM with the `memmap=` kernel parameter and the E820 memory map. The ARM64 Device Tree (DT) boot flow, however, has no E820, and a reserved range cannot be expressed reliably in the same way.

On ARM64, we copy the DTB that extlinux loads, add an `nvmevirt@...` node under `/reserved-memory`, and give the node the `no-map` property. The kernel then does not manage that physical range as ordinary System RAM (nor include it in its linear mapping), so NVMeVirt can use it as dedicated backing memory. We also added a check at module load time that rejects the range immediately if it still intersects `IORESOURCE_SYSTEM_RAM`.

The initial plan also included booting with `iommu.passthrough=1` to bypass the SMMU globally. On the target Tegra platform, however, global passthrough could affect the stability of other platform devices, particularly the XUSB (USB) controller. The final verification script therefore does not enable global passthrough by default and turns it on only by explicit opt-in. Instead, Phase 2 checks whether the NVMeVirt synthetic PCI device has been placed in an IOMMU group; if it has no group, or its group's domain type is identity or unmanaged, direct DMA is considered possible.

### 2. x86 APIC/MSI Dependency

The original interrupt path depends heavily on the x86 APIC and on the IRQ chip's `irq_retrigger` operation. ARM64 has no APIC, and a synthetic PCI bus does not automatically get a regular platform MSI controller either. The original APIC fast path therefore cannot be used as-is on ARM64.

The port confines the x86 APIC header and the fast IRQ-handling path to x86-only code. On ARM64, the module creates its own software parent IRQ domain and stacks a PCI-MSI child domain on top of it. Since the interrupt capability NVMeVirt advertises is MSI-X, the MSI domain flags are also set for MSI-X (`MSI_FLAG_PCI_MSIX`). To deliver a completion interrupt, NVMeVirt looks up the Linux virq for the MSI-X table entry index with `pci_irq_vector()`, and on ARM64 dispatches it to the host NVMe driver's IRQ handler through `generic_handle_irq()`.

With this change, the APIC-specific path on x86 is preserved, while ARM64 gets a separate synthetic MSI delivery path. Root bus creation follows the same split: x86 keeps the existing `pci_scan_bus()` path, and only ARM64 uses a `pci_create_root_bus()`-based path so that the MSI domain can be attached to the bus before its devices are scanned.

### 3. BAR and Doorbell Memory Attributes

On ARM64, mapping the same physical address with different memory attributes at the same time is dangerous. The host NVMe driver maps the PCI BAR with `ioremap()`/`pci_iomap()`-style helpers and accesses it as Device memory. If NVMeVirt internally accessed the same physical memory backing the BAR as Normal cacheable memory, the ARM64 memory model would allow unpredictable behavior.

In the final design, the NVMe controller BAR and the MSI-X table are treated strictly as MMIO regions. Inside NVMeVirt, these regions are also mapped with `ioremap()`, and they are initialized and accessed with `memset_io()`, `readl()`, `writel()`, `readq()`, and `writeq()`. Doorbell register accesses likewise go through helpers built on these I/O accessors.

The SSD backing-storage region, in contrast, is an ordinary data buffer and remains Normal memory as before. The key idea is to separate the memory attributes of the register/MMIO region from those of the storage backing region, which gives a safe access model on ARM64.

### 4. Synthetic PCI Device DMA Coherency

NVMeVirt is not a real PCIe device; its kernel threads emulate the DMA operations of an NVMe device. The host NVMe driver allocates its admin and I/O queues from DMA memory, and NVMeVirt follows their physical addresses to fill in completion entries. On x86-64, differences in cache coherency and memory attributes never visibly surfaced. On ARM64, however, if the DMA coherency attribute of the synthetic PCI device is wrong, the host driver may not see completions in time.

In fact, during a full probe the MSI-X interrupt itself was delivered, but the host NVMe driver failed to consume the admin completion, and the probe timed out. The fix was to mark the ARM64 synthetic PCI function as a DMA-coherent device (`dev->dma_coherent = true`). Since NVMeVirt's "device DMA" is actually performed from CPU context, this makes the host NVMe driver use coherent (cacheable) queue memory, so the driver and NVMeVirt observe the same data.

After this change, device discovery, namespace discovery, admin commands, and filesystem I/O all worked correctly.

### 5. NVMe Identify Correctness

During full I/O verification, there were runs in which only `nvme id-ctrl` failed. This was not an ARM64 interrupt or memory-attribute issue but a pre-existing gap in NVMeVirt: its Identify Controller response did not fill in the `vid` and `ssvid` fields.

The fix fills the Identify Controller data structure with NVMeVirt's PCI vendor ID and PCI subsystem vendor ID. As a result, the vendor identity in PCI configuration space and the controller identity returned by the NVMe admin command are now consistent, and the `nvme-cli`-based checks pass as well.

### 6. SSD Target Kernel Floating-Point Restriction

The NVM target builds only `simple_ftl.o` in addition to the core, whereas the SSD target also builds `conv_ftl.o`, `ssd.o`, and `channel_model.o`. On this path, `convparams` used a `double` over-provisioning value. The ARM64 kernel is built with `-mgeneral-regs-only` to keep ordinary kernel code from using FP/SIMD registers, so the SSD target failed to build.

Rather than relaxing the kernel build options, we expressed the same computation in integer arithmetic. `OP_AREA_PERCENT` is now the integer percentage `7` instead of the ratio `0.07`, and `pba_pcent` is computed as `100 + OP_AREA_PERCENT`. The result is still `107`, so the logical capacity calculation is unchanged while the code satisfies the ARM64 kernel's FP restriction.

## Verification Strategy

ARM64 verification follows the two-phase flow in `advanced_os/verify_nvmev_arm64.sh`.

Phase 1 is the preparation step before reboot. It copies the current DTB, adds a reserved-memory carveout for NVMeVirt, and replaces the active `FDT` entry in extlinux with the patched DTB. It also records the CPU list for the NVMeVirt worker threads and the memory range in a state file. Global IOMMU passthrough is off by default and is enabled only through an environment variable (`NVMEV_ARM64_IOMMU_PASSTHROUGH=1`) when an experiment needs it.

Phase 2 is the verification step after reboot. It first checks that the reserved-memory node is actually present in the booted DT, and that the range lies within physical memory while having been removed from System RAM. It then runs, in order, the module build, module load, PCI/SMMU state checks, NVMe discovery, and the full I/O test.

The full I/O test is run explicitly, only after the safe probe passes. Its pass criteria are:

- Module load/unload succeeds
- The synthetic PCI device is discovered
- The NVMe controller and namespace are discovered
- `nvme id-ctrl`, `nvme id-ns`, and `nvme smart-log` succeed
- `mkfs.ext4` and mount succeed
- File write/read integrity checks pass
- Direct-I/O sequential write/read with `dd` succeeds
- The `/proc/nvmev` interface is accessible

The final verification on the ARM64 target reported `OVERALL: PASS (41/41 passed)`.

## Result and Remaining Notes

In the final state, NVMeVirt is recognized as a real block device on the ARM64 target and handles both NVMe admin commands and filesystem-level I/O. On this ARM64 platform, the port that removes or replaces the x86-64 assumptions can therefore be considered complete.

x86-64 regressions, however, still need to be checked separately on an x86-64 machine with `advanced_os/verify_nvmev_x86-64.sh`. The porting changes were isolated to architecture-dependent paths wherever possible, but some of them touch common code paths, such as the PCI/BAR helpers and the Identify Controller response, so the existing x86 behavior must be re-verified.

The verification script based on staged probing and detailed snapshots, which was used during ARM64 bring-up, is kept for reference in `advanced_os/verify_nvmev_arm64_debug.sh`. The final code and the default `verify_nvmev_arm64.sh` drop the bring-up-only hooks and keep only the paths needed to verify actual operation.
