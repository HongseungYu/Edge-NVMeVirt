# NVMeVirt ARM64 Porting Notes

## Overview

NVMeVirt 원본 구현은 x86-64 환경을 전제로 작성되어 있다. 특히 PCI/MSI interrupt 전달, APIC 기반 IRQ 처리, boot-time memory reservation, 그리고 PCI BAR 접근 방식이 x86 Linux의 동작 모델에 맞춰져 있었다. 이 구조는 x86-64에서는 `advanced_os/verify_nvmev_x86-64.sh` 검증을 통과하지만, ARM64 플랫폼에서는 같은 전제가 그대로 성립하지 않는다.

이번 포팅의 목표는 기존 x86-64 동작을 유지하면서 ARM64에서도 NVMeVirt가 virtual NVMe device로 인식되고, namespace 생성과 실제 block I/O까지 수행되도록 만드는 것이었다. 최종 검증은 ARM64 target에서 module build/load, PCI/NVMe discovery, NVMe admin command, filesystem 생성, mount, data integrity, direct I/O, unload까지 확인하는 방식으로 진행했다.

## Porting Challenges and Solutions

### 1. Boot-Time Memory Reservation

NVMeVirt는 host memory 일부를 virtual SSD backing store와 MMIO register backing 영역으로 사용한다. x86-64에서는 `memmap=` kernel parameter와 e820 memory map을 이용해 해당 물리 주소 범위를 System RAM에서 제외하는 방식이 자연스럽다. 반면 ARM64 DT boot flow에서는 e820이 없고, 같은 방식으로 reserved range를 안정적으로 표현하기 어렵다.

ARM64에서는 extlinux가 참조하는 DTB를 복사해 `/reserved-memory` 아래에 `nvmevirt@...` node를 추가하고, 해당 node에 `no-map` 속성을 부여했다. 이렇게 하면 kernel이 해당 물리 주소 범위를 일반 System RAM으로 관리하지 않으므로 NVMeVirt가 독점 backing memory로 사용할 수 있다. module load 시에도 이 범위가 여전히 `IORESOURCE_SYSTEM_RAM`과 교차하면 즉시 거부하도록 검증을 추가했다.

초기 계획에는 global SMMU bypass를 위해 `iommu.passthrough=1`을 사용하는 경로도 포함되어 있었다. 그러나 target Tegra 환경에서는 global passthrough가 다른 platform device, 특히 XUSB 쪽 안정성에 영향을 줄 수 있었다. 최종 검증 스크립트는 global passthrough를 기본값으로 사용하지 않고, 필요할 때만 opt-in으로 켜도록 했다. 대신 Phase 2에서 NVMeVirt synthetic PCI device가 IOMMU group에 들어갔는지 확인하고, group이 없거나 identity/unmanaged 상태이면 direct DMA가 가능하다고 판단한다.

### 2. x86 APIC/MSI Dependency

원본 interrupt 경로는 x86 APIC와 IRQ retrigger 동작에 강하게 의존한다. ARM64에는 APIC가 없고, synthetic PCI bus에서 일반적인 platform MSI controller를 자동으로 얻을 수도 없다. 따라서 원본의 APIC fast path를 ARM64에서 그대로 사용할 수 없다.

포팅에서는 x86 APIC header와 fast IRQ handling을 x86 전용 코드로 제한했다. ARM64에서는 module 내부에 software parent IRQ domain을 만들고, 그 위에 PCI-MSI child domain을 생성했다. NVMeVirt가 advertise하는 interrupt capability는 MSI-X이므로 MSI domain flag도 MSI-X 중심으로 설정했다. 실제 completion interrupt 전달은 MSI-X table entry 번호에서 `pci_irq_vector()`로 Linux virq를 찾고, ARM64에서는 `generic_handle_irq()`를 통해 host NVMe driver의 IRQ handler로 전달한다.

이 변경으로 x86의 APIC-specific path는 보존하면서, ARM64에서는 별도의 synthetic MSI delivery path를 사용할 수 있게 되었다. PCI root bus 생성도 x86에서는 기존 `pci_scan_bus()` 경로를 유지하고, ARM64에서만 MSI domain을 붙이기 위해 `pci_create_root_bus()` 기반 경로를 사용한다.

### 3. BAR and Doorbell Memory Attributes

ARM64에서는 같은 physical address를 서로 다른 memory attribute로 동시에 매핑하는 것이 위험하다. NVMe host driver는 PCI BAR를 `pci_iomap()` 계열로 Device memory처럼 접근한다. 반면 NVMeVirt 내부가 같은 BAR backing physical address를 normal cacheable memory처럼 접근하면, ARM64 memory model에서는 unpredictable behavior가 발생할 수 있다.

최종 구조에서는 NVMe controller BAR와 MSI-X table을 명확히 MMIO 영역으로 취급한다. NVMeVirt 내부에서도 이 영역은 `ioremap()`으로 매핑하고, 초기화와 접근에는 `memset_io()`, `readl()`, `writel()`, `readq()`, `writeq()`를 사용한다. Doorbell register 접근도 helper를 통해 IO accessor로 통일했다.

반대로 SSD backing storage 영역은 일반 data buffer 성격이므로 기존처럼 normal memory로 유지한다. 즉 register/MMIO 영역과 storage backing 영역의 memory attribute를 분리해 ARM64에서 안전한 접근 모델을 만든 것이 핵심이다.

### 4. Synthetic PCI Device DMA Coherency

NVMeVirt는 실제 PCIe 장치가 아니라 kernel thread가 NVMe device의 DMA 동작을 흉내 내는 구조다. Host NVMe driver는 admin queue와 I/O queue를 DMA memory로 할당하고, NVMeVirt는 그 물리 주소를 따라가 completion entry를 채운다. x86-64에서는 cache coherency와 memory attribute 차이가 크게 드러나지 않았지만, ARM64에서는 synthetic PCI device의 DMA coherency 속성이 맞지 않으면 host driver가 completion을 제때 보지 못할 수 있다.

실제로 full probe 과정에서 MSI-X interrupt 자체는 전달되지만, host NVMe driver가 admin completion을 정상 소비하지 못해 probe timeout이 발생했다. 최종 해결은 ARM64 synthetic PCI function을 DMA coherent device로 표시하는 것이었다. NVMeVirt의 "device DMA"가 CPU context에서 수행된다는 점을 반영해, host NVMe driver가 coherent queue memory를 사용하도록 만든 것이다.

이 변경 이후 device discovery, namespace discovery, admin command, filesystem I/O가 정상 동작했다.

### 5. NVMe Identify Correctness

Full I/O 검증 중 `nvme id-ctrl`만 실패하는 경우가 있었다. 이 문제는 ARM64 interrupt나 memory attribute 문제가 아니라, NVMeVirt의 Identify Controller response가 `vid`와 `ssvid`를 채우지 않던 기존 기능 누락이었다.

최종 수정에서는 Identify Controller data structure에 NVMeVirt vendor id와 subsystem vendor id를 채워 넣었다. 그 결과 PCI config space의 vendor identity와 NVMe admin command가 반환하는 controller identity가 일관되게 되었고, `nvme-cli` 기반 검증도 통과했다.

## Verification Strategy

ARM64 검증은 `advanced_os/verify_nvmev_arm64.sh`의 two-phase flow로 구성했다.

Phase 1은 reboot 전 준비 단계다. 현재 DTB를 복사해 NVMeVirt용 reserved-memory carveout을 추가하고, extlinux의 active FDT 항목을 patched DTB로 교체한다. 또한 NVMeVirt worker에 사용할 CPU 목록과 memory range를 state file에 기록한다. Global IOMMU passthrough는 기본적으로 켜지지 않으며, 실험이 필요한 경우 환경 변수로만 opt-in한다.

Phase 2는 reboot 후 검증 단계다. 먼저 boot된 DT에 reserved-memory node가 실제로 존재하는지, 해당 범위가 live memory 안에 있으면서도 System RAM에서는 제거되었는지 확인한다. 그 다음 module build, module load, PCI/SMMU 상태 확인, NVMe discovery, full I/O test를 순서대로 수행한다.

Full I/O test는 safe probe가 통과한 뒤 명시적으로 실행한다. 통과 조건은 다음과 같다.

- module load/unload 성공
- synthetic PCI device discovery 성공
- NVMe controller와 namespace discovery 성공
- `nvme id-ctrl`, `nvme id-ns`, `nvme smart-log` 성공
- `mkfs.ext4`, mount 성공
- file write/read integrity 성공
- direct `dd` sequential write/read 성공
- `/proc/nvmev` interface 접근 성공

최종 ARM64 target 검증 결과는 `OVERALL: PASS (41/41 passed)`였다.

## Result and Remaining Notes

최종 결과 기준으로 NVMeVirt는 ARM64 target에서 실제 block device로 인식되고, NVMe admin command와 filesystem-level I/O를 모두 수행했다. 따라서 해당 ARM64 환경에서는 x86-64 전제를 제거하거나 대체하는 포팅이 성공적으로 완료되었다고 볼 수 있다.

다만 x86-64 regression은 별도의 x86-64 machine에서 `advanced_os/verify_nvmev_x86-64.sh`로 확인해야 한다. 포팅 변경은 가능한 한 architecture-dependent path에 격리했지만, PCI/BAR helper와 Identify Controller 응답처럼 공통 경로에 닿는 변경도 있으므로 기존 x86 동작 확인이 필요하다.

ARM64 bring-up 과정에서 사용한 staged probe와 상세 snapshot 기반 검증 스크립트는 참고용으로 `advanced_os/verify_nvmev_arm64_debug.sh`에 남겨 두었다. 최종 기능 코드와 기본 `verify_nvmev_arm64.sh`에서는 bring-up 전용 hook을 제거하고, 실제 동작 검증에 필요한 경로만 유지했다.
