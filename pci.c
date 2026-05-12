// SPDX-License-Identifier: GPL-2.0-only

#include <linux/pci.h>
#include <linux/irq.h>
#include <linux/irqdesc.h>
#include <linux/irqdomain.h>
#include <linux/irqflags.h>
#include <linux/version.h>

#include <linux/percpu-defs.h>
#include <linux/sched/clock.h>

#if defined(CONFIG_X86) && defined(CONFIG_NVMEV_FAST_X86_IRQ_HANDLING)
#include <asm/apic.h>
#endif

#include "nvmev.h"
#include "pci.h"

#if defined(CONFIG_X86) && defined(CONFIG_NVMEV_FAST_X86_IRQ_HANDLING)
static int apicid_to_cpuid[256];

static void __init_apicid_to_cpuid(void)
{
	int i;
	for_each_possible_cpu(i) {
		apicid_to_cpuid[per_cpu(x86_cpu_to_apicid, i)] = i;
	}
}

static void __signal_irq(const char *type, unsigned int irq)
{
	struct irq_data *irqd = irq_get_irq_data(irq);
	struct irq_cfg *irqc = irqd_cfg(irqd);

	unsigned int target = irqc->dest_apicid;
	unsigned int target_cpu = apicid_to_cpuid[target];

	NVMEV_DEBUG_VERBOSE("irq: %s %d, vector %d, apic %d, cpu %d\n", type, irq, irqc->vector, target, target_cpu);
	apic->send_IPI(target_cpu, irqc->vector);

	return;
}
#else
static void __signal_irq(const char *type, unsigned int irq)
{
#ifdef CONFIG_ARM64
	unsigned long flags;

	NVMEV_DEBUG_VERBOSE("irq: %s %d\n", type, irq);
	local_irq_save(flags);
	generic_handle_irq(irq);
	local_irq_restore(flags);
#else
	struct irq_data *data = irq_get_irq_data(irq);
	struct irq_chip *chip = irq_data_get_irq_chip(data);

#ifdef CONFIG_X86
	NVMEV_DEBUG_VERBOSE("irq: %s %d, vector %d\n", type, irq, irqd_cfg(data)->vector);
#else
	NVMEV_DEBUG_VERBOSE("irq: %s %d\n", type, irq);
#endif
	BUG_ON(!chip->irq_retrigger);
	chip->irq_retrigger(data);
#endif
}
#endif

static void __process_msi_irq(int msi_index)
{
	int virq = pci_irq_vector(nvmev_vdev->pdev, msi_index);

	if (virq < 0)
		BUG();

	__signal_irq("msi", virq);
}

void nvmev_signal_irq(int msi_index)
{
	if (nvmev_vdev->pdev->msix_enabled) {
		__process_msi_irq(msi_index);
	} else {
		nvmev_vdev->pcihdr->sts.is = 1;

		__signal_irq("int", nvmev_vdev->pdev->irq);
	}
}

#define NVMEV_BAR_CAP		0x00
#define NVMEV_BAR_VS		0x08
#define NVMEV_BAR_CC		0x14
#define NVMEV_BAR_CSTS		0x1c
#define NVMEV_BAR_AQA		0x24
#define NVMEV_BAR_ASQ		0x28
#define NVMEV_BAR_ACQ		0x30

#define NVMEV_AQA_ASQS(aqa)	((aqa) & 0xfff)
#define NVMEV_AQA_ACQS(aqa)	(((aqa) >> 16) & 0xfff)
#define NVMEV_CC_EN(cc)		((cc) & 0x1)
#define NVMEV_CC_SHN(cc)	(((cc) >> 14) & 0x3)
#define NVMEV_CSTS_RDY		0x1
#define NVMEV_CSTS_SHST_MASK	(0x3 << 2)
#define NVMEV_CSTS_SHST_COMPLETE (0x2 << 2)

static inline void __iomem *__nvmev_bar_addr(u32 offset)
{
	return (void __iomem *)((u8 __iomem *)nvmev_vdev->bar + offset);
}

static inline u32 __nvmev_bar_read32(u32 offset)
{
	return readl(__nvmev_bar_addr(offset));
}

static inline u64 __nvmev_bar_read64(u32 offset)
{
	return readq(__nvmev_bar_addr(offset));
}

static inline void __nvmev_bar_write32(u32 offset, u32 val)
{
	writel(val, __nvmev_bar_addr(offset));
}

static inline void __nvmev_bar_write64(u32 offset, u64 val)
{
	writeq(val, __nvmev_bar_addr(offset));
}

/*
 * The host device driver can change multiple locations in the BAR.
 * In a real device, these changes are processed one after the other,
 * preserving their requesting order. However, in NVMeVirt, the changes
 * can be DETECTED with the dispatcher, obsecuring the order between
 * changes that are made between the checking loop. Thus, we have to
 * process the changes strategically, in an order that are supposed
 * to be...
 *
 * Also, memory barrier is not necessary here since BAR-related
 * operations are only processed by the dispatcher.
 *
 * Returns true if an event is processed.
 */
bool nvmev_proc_bars(void)
{
	volatile struct __nvme_bar *old_bar = nvmev_vdev->old_bar;
	struct nvmev_admin_queue *queue = nvmev_vdev->admin_q;
	u32 aqa = __nvmev_bar_read32(NVMEV_BAR_AQA);
	u64 asq = __nvmev_bar_read64(NVMEV_BAR_ASQ);
	u64 acq = __nvmev_bar_read64(NVMEV_BAR_ACQ);
	u32 cc = __nvmev_bar_read32(NVMEV_BAR_CC);
	u32 csts = __nvmev_bar_read32(NVMEV_BAR_CSTS);
	unsigned int num_pages, i;

	if (old_bar->aqa != aqa) {
		// Initalize admin queue
		NVMEV_DEBUG("%s: aqa 0x%x -> 0x%x\n", __func__, old_bar->aqa, aqa);
		old_bar->aqa = aqa;

		if (!queue) {
			queue = kzalloc(sizeof(struct nvmev_admin_queue), GFP_KERNEL);
			BUG_ON(queue == NULL);
			WRITE_ONCE(nvmev_vdev->admin_q, queue);
		} else {
			queue = nvmev_vdev->admin_q;
		}

		queue->cq_head = 0;
		queue->phase = 1;
		queue->sq_depth = NVMEV_AQA_ASQS(aqa) + 1; /* asqs and acqs are 0-based */
		queue->cq_depth = NVMEV_AQA_ACQS(aqa) + 1;

		nvmev_db_write(0, 0);
		nvmev_db_write(1, 0);
		nvmev_vdev->old_dbs[0] = 0;
		nvmev_vdev->old_dbs[1] = 0;

		goto out;
	}
	if (old_bar->asq != asq) {
		if (queue == NULL) {
			/*
			 * asq/acq can't be updated later than aqa, but in an unlikely case, this
			 * can be triggered before an aqa update due to memory re-ordering and lack
			 * of barriers.
			 *
			 * If that's the case, simply run the loop again after a full barrier so
			 * that the aqa code (initializing the admin queue) can run prior to this.
			 */
			NVMEV_INFO("asq triggered before aqa, retrying\n");
			goto out;
		}

		NVMEV_DEBUG("%s: asq 0x%llx -> 0x%llx\n", __func__, old_bar->asq, asq);
		old_bar->asq = asq;

		if (queue->nvme_sq) {
			kfree(queue->nvme_sq);
			queue->nvme_sq = NULL;
		}

		queue->sq_depth = NVMEV_AQA_ASQS(old_bar->aqa) + 1; /* asqs and acqs are 0-based */

		num_pages = DIV_ROUND_UP(queue->sq_depth * sizeof(struct nvme_command), PAGE_SIZE);
		queue->nvme_sq = kcalloc(num_pages, sizeof(struct nvme_command *), GFP_KERNEL);
		BUG_ON(!queue->nvme_sq && "Error on setup admin submission queue");

		for (i = 0; i < num_pages; i++) {
			queue->nvme_sq[i] =
				page_address(pfn_to_page(asq >> PAGE_SHIFT) + i);
		}

		nvmev_db_write(0, 0);
		nvmev_vdev->old_dbs[0] = 0;

		goto out;
	}
	if (old_bar->acq != acq) {
		if (queue == NULL) {
			// See comment above
			NVMEV_INFO("acq triggered before aqa, retrying\n");
			goto out;
		}

		NVMEV_DEBUG("%s: acq 0x%llx -> 0x%llx\n", __func__, old_bar->acq, acq);
		old_bar->acq = acq;

		if (queue->nvme_cq) {
			kfree(queue->nvme_cq);
			queue->nvme_cq = NULL;
		}

		queue->cq_depth = NVMEV_AQA_ACQS(old_bar->aqa) + 1; /* asqs and acqs are 0-based */

		num_pages =
			DIV_ROUND_UP(queue->cq_depth * sizeof(struct nvme_completion), PAGE_SIZE);
		queue->nvme_cq = kcalloc(num_pages, sizeof(struct nvme_completion *), GFP_KERNEL);
		BUG_ON(!queue->nvme_cq && "Error on setup admin completion queue");
		queue->cq_head = 0;
		queue->phase = 1;

		for (i = 0; i < num_pages; i++) {
			queue->nvme_cq[i] =
				page_address(pfn_to_page(acq >> PAGE_SHIFT) + i);
		}

		nvmev_db_write(1, 0);
		nvmev_vdev->old_dbs[1] = 0;

		goto out;
	}
	if (old_bar->cc != cc) {
		NVMEV_DEBUG("%s: cc 0x%x:%x -> 0x%x:%x\n", __func__, old_bar->cc,
			    old_bar->csts, cc, csts);
		/* Enable */
		if (NVMEV_CC_EN(cc) == 1) {
			if (nvmev_vdev->admin_q) {
				csts |= NVMEV_CSTS_RDY;
			} else {
				WARN_ON("Enable device without init admin q");
			}
		} else if (NVMEV_CC_EN(cc) == 0) {
			csts &= ~NVMEV_CSTS_RDY;
		}

		/* Shutdown */
		if (NVMEV_CC_SHN(cc) == 1) {
			csts = (csts & ~NVMEV_CSTS_SHST_MASK) | NVMEV_CSTS_SHST_COMPLETE;

			nvmev_db_write(0, 0);
			nvmev_db_write(1, 0);
			nvmev_vdev->old_dbs[0] = 0;
			nvmev_vdev->old_dbs[1] = 0;
			nvmev_vdev->admin_q->cq_head = 0;
		}

		__nvmev_bar_write32(NVMEV_BAR_CSTS, csts);
		old_bar->cc = cc;
		old_bar->csts = csts;

		goto out;
	}

	return false;

out:
	smp_mb();
	return true;
}

static int nvmev_pci_read(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 *val)
{
	if (devfn != 0)
		return 1;

	memcpy(val, nvmev_vdev->virtDev + where, size);

	NVMEV_DEBUG_VERBOSE("[R] 0x%x, size: %d, val: 0x%x\n", where, size, *val);

	return 0;
};

static int nvmev_pci_write(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 _val)
{
	u32 mask = ~(0U);
	u32 val = 0x00;
	int target = where;

	WARN_ON(size > sizeof(_val));

	memcpy(&val, nvmev_vdev->virtDev + where, size);

	if (where < OFFS_PCI_PM_CAP) {
		// PCI_HDR
		if (target == PCI_COMMAND) {
			mask = PCI_COMMAND_INTX_DISABLE;
			if ((val ^ _val) & PCI_COMMAND_INTX_DISABLE) {
				nvmev_vdev->intx_disabled = !!(_val & PCI_COMMAND_INTX_DISABLE);
				if (!nvmev_vdev->intx_disabled) {
					nvmev_vdev->pcihdr->sts.is = 0;
				}
			}
		} else if (target == PCI_STATUS) {
			mask = 0xF200;
		} else if (target == PCI_BIST) {
			mask = PCI_BIST_START;
		} else if (target == PCI_BASE_ADDRESS_0) {
			mask = 0xFFFFC000;
		} else if (target == PCI_INTERRUPT_LINE) {
			mask = 0xFF;
		} else {
			mask = 0x0;
		}
	} else if (where < OFFS_PCI_MSIX_CAP) {
		// PCI_PM_CAP
	} else if (where < OFFS_PCIE_CAP) {
		// PCI_MSIX_CAP
		target -= OFFS_PCI_MSIX_CAP;
		if (target == PCI_MSIX_FLAGS) {
			mask = PCI_MSIX_FLAGS_MASKALL | /* 0x4000 */
			       PCI_MSIX_FLAGS_ENABLE; /* 0x8000 */

			if ((nvmev_vdev->pdev) && ((val ^ _val) & PCI_MSIX_FLAGS_ENABLE)) {
				nvmev_vdev->pdev->msix_enabled = !!(_val & PCI_MSIX_FLAGS_ENABLE);
			}
		} else {
			mask = 0x0;
		}
	} else if (where < OFFS_PCI_EXT_CAP) {
		// PCIE_CAP
	} else {
		// PCI_EXT_CAP
	}
	NVMEV_DEBUG_VERBOSE("[W] 0x%x, mask: 0x%x, val: 0x%x -> 0x%x, size: %d, new: 0x%x\n", where, mask,
		    val, _val, size, (val & (~mask)) | (_val & mask));

	val = (val & (~mask)) | (_val & mask);
	memcpy(nvmev_vdev->virtDev + where, &val, size);

	return 0;
};

static struct pci_ops nvmev_pci_ops = {
	.read = nvmev_pci_read,
	.write = nvmev_pci_write,
};

#ifdef CONFIG_X86
static struct pci_sysdata nvmev_pci_sysdata = {
	.domain = NVMEV_PCI_DOMAIN_NUM,
	.node = 0,
};
#endif

#if defined(CONFIG_ARM64) && defined(CONFIG_PCI_MSI_IRQ_DOMAIN) && defined(CONFIG_GENERIC_MSI_IRQ_DOMAIN)
static struct irq_domain *nvmev_msi_parent_domain;
static struct irq_domain *nvmev_pci_msi_domain;
static struct fwnode_handle *nvmev_msi_parent_fwnode;
static struct fwnode_handle *nvmev_pci_msi_fwnode;

static void nvmev_msi_parent_compose_msg(struct irq_data *data, struct msi_msg *msg)
{
	memset(msg, 0, sizeof(*msg));
	msg->data = (u32)irqd_to_hwirq(data);
}

static int nvmev_msi_parent_set_affinity(struct irq_data *data, const struct cpumask *dest,
					 bool force)
{
	return IRQ_SET_MASK_OK_DONE;
}

static struct irq_chip nvmev_msi_parent_chip = {
	.name = "NVMeVirt-MSI-parent",
	.irq_compose_msi_msg = nvmev_msi_parent_compose_msg,
	.irq_set_affinity = nvmev_msi_parent_set_affinity,
};

static int nvmev_msi_parent_alloc(struct irq_domain *domain, unsigned int virq,
				  unsigned int nr_irqs, void *arg)
{
	msi_alloc_info_t *info = arg;
	irq_hw_number_t hwirq = info ? info->hwirq : virq;
	unsigned int i;
	int ret;

	for (i = 0; i < nr_irqs; i++) {
		ret = irq_domain_set_hwirq_and_chip(domain, virq + i, hwirq + i,
						    &nvmev_msi_parent_chip, NULL);
		if (ret)
			return ret;
	}

	return 0;
}

static void nvmev_msi_parent_free(struct irq_domain *domain, unsigned int virq,
				  unsigned int nr_irqs)
{
	irq_domain_free_irqs_common(domain, virq, nr_irqs);
}

static const struct irq_domain_ops nvmev_msi_parent_domain_ops = {
	.alloc = nvmev_msi_parent_alloc,
	.free = nvmev_msi_parent_free,
};

static struct irq_chip nvmev_pci_msi_chip = {
	.name = "NVMeVirt-PCI-MSI",
};

static struct msi_domain_info nvmev_pci_msi_domain_info = {
	.flags = MSI_FLAG_USE_DEF_DOM_OPS | MSI_FLAG_USE_DEF_CHIP_OPS | MSI_FLAG_PCI_MSIX,
	.chip = &nvmev_pci_msi_chip,
	.handler = handle_simple_irq,
	.handler_name = "edge",
};

static bool __init_nvmev_msi_domain(void)
{
	if (nvmev_pci_msi_domain)
		return true;

	nvmev_msi_parent_fwnode = irq_domain_alloc_named_fwnode("NVMeVirt-MSI-parent");
	if (!nvmev_msi_parent_fwnode)
		return false;

	nvmev_msi_parent_domain =
		irq_domain_create_hierarchy(NULL, 0, 0, nvmev_msi_parent_fwnode,
					    &nvmev_msi_parent_domain_ops, NULL);
	if (!nvmev_msi_parent_domain)
		goto err_parent_domain;

	nvmev_pci_msi_fwnode = irq_domain_alloc_named_fwnode("NVMeVirt-PCI-MSI");
	if (!nvmev_pci_msi_fwnode)
		goto err_child_fwnode;

	nvmev_pci_msi_domain =
		pci_msi_create_irq_domain(nvmev_pci_msi_fwnode,
					  &nvmev_pci_msi_domain_info,
					  nvmev_msi_parent_domain);
	if (!nvmev_pci_msi_domain)
		goto err_child_domain;

	return true;

err_child_domain:
	irq_domain_free_fwnode(nvmev_pci_msi_fwnode);
	nvmev_pci_msi_fwnode = NULL;
err_child_fwnode:
	irq_domain_remove(nvmev_msi_parent_domain);
	nvmev_msi_parent_domain = NULL;
err_parent_domain:
	irq_domain_free_fwnode(nvmev_msi_parent_fwnode);
	nvmev_msi_parent_fwnode = NULL;
	return false;
}

static void __destroy_nvmev_msi_domain(void)
{
	if (nvmev_pci_msi_domain) {
		irq_domain_remove(nvmev_pci_msi_domain);
		nvmev_pci_msi_domain = NULL;
	}

	if (nvmev_pci_msi_fwnode) {
		irq_domain_free_fwnode(nvmev_pci_msi_fwnode);
		nvmev_pci_msi_fwnode = NULL;
	}

	if (nvmev_msi_parent_domain) {
		irq_domain_remove(nvmev_msi_parent_domain);
		nvmev_msi_parent_domain = NULL;
	}

	if (nvmev_msi_parent_fwnode) {
		irq_domain_free_fwnode(nvmev_msi_parent_fwnode);
		nvmev_msi_parent_fwnode = NULL;
	}
}

static void __attach_nvmev_msi_domain(struct pci_bus *bus)
{
	dev_set_msi_domain(&bus->dev, nvmev_pci_msi_domain);
}

static void __attach_nvmev_device_msi_domain(struct pci_dev *dev)
{
	dev_set_msi_domain(&dev->dev, nvmev_pci_msi_domain);
}
#elif defined(CONFIG_ARM64)
static bool __init_nvmev_msi_domain(void)
{
	NVMEV_ERROR("ARM64 requires CONFIG_PCI_MSI_IRQ_DOMAIN and CONFIG_GENERIC_MSI_IRQ_DOMAIN\n");
	return false;
}

static void __destroy_nvmev_msi_domain(void)
{
}

static void __attach_nvmev_msi_domain(struct pci_bus *bus)
{
}

static void __attach_nvmev_device_msi_domain(struct pci_dev *dev)
{
}
#else
static bool __init_nvmev_msi_domain(void)
{
	return true;
}

static void __destroy_nvmev_msi_domain(void)
{
}

static void __attach_nvmev_msi_domain(struct pci_bus *bus)
{
}

static void __attach_nvmev_device_msi_domain(struct pci_dev *dev)
{
}
#endif

static void __force_nvmev_bar_resource(struct pci_dev *dev)
{
	struct resource *res = &dev->resource[0];
	resource_size_t start = nvmev_vdev->config.memmap_start;
	resource_size_t end = start + (PAGE_SIZE * 4) - 1;

	res->start = start;
	res->end = end;
	res->flags = IORESOURCE_MEM | IORESOURCE_MEM_64;
	res->parent = &iomem_resource;

	nvmev_vdev->pcihdr->mlbar.tp = PCI_BASE_ADDRESS_MEM_TYPE_64 >> 1;
	nvmev_vdev->pcihdr->mlbar.ba = (start & 0xFFFFFFFF) >> 14;
	nvmev_vdev->pcihdr->mulbar = start >> 32;
}

static void __init_nvme_ctrl_regs(struct pci_dev *dev)
{
	resource_size_t bar_start = nvmev_vdev->config.memmap_start;
	struct nvme_ctrl_regs init_bar = {
		.cap = {
			.to = 1,
			.mpsmin = 0,
			.mqes = 1024 - 1, // 0-based value
#if (SUPPORTED_SSD_TYPE(ZNS))
			.css = CAP_CSS_BIT_SPECIFIC,
#endif
		},
		.vs = {
			.mjr = 1,
			.mnr = 0,
		},
	};
	void __iomem *bar;

	bar = ioremap(bar_start, PAGE_SIZE * 2);
	BUG_ON(!bar);

	nvmev_vdev->bar = bar;

	memset_io(nvmev_vdev->bar, 0x0, PAGE_SIZE * 2);

	nvmev_vdev->dbs = (u32 __iomem *)((u8 __iomem *)bar + PAGE_SIZE);

	__nvmev_bar_write64(NVMEV_BAR_CAP, init_bar.u_cap);
	__nvmev_bar_write32(NVMEV_BAR_VS, init_bar.u_vs);
}

#ifndef CONFIG_X86
static struct resource nvmev_pci_busn_resource = {
	.name = "NVMeVirt busn",
	.start = NVMEV_PCI_BUS_NUM,
	.end = NVMEV_PCI_BUS_NUM,
	.flags = IORESOURCE_BUS,
};
#endif

static struct pci_bus *__create_pci_bus(void)
{
#ifndef CONFIG_X86
	LIST_HEAD(resources);
#endif
	struct pci_bus *bus = NULL;
	struct pci_dev *dev;
	int node = cpu_to_node(nvmev_vdev->config.cpu_nr_dispatcher);

#ifdef CONFIG_X86
	nvmev_pci_sysdata.node = node;
	bus = pci_scan_bus(NVMEV_PCI_BUS_NUM, &nvmev_pci_ops, &nvmev_pci_sysdata);
#else

	nvmev_pci_busn_resource.start = NVMEV_PCI_BUS_NUM;
	nvmev_pci_busn_resource.end = NVMEV_PCI_BUS_NUM;
	nvmev_pci_busn_resource.flags = IORESOURCE_BUS;

	pci_add_resource(&resources, &ioport_resource);
	pci_add_resource(&resources, &iomem_resource);
	pci_add_resource(&resources, &nvmev_pci_busn_resource);

	bus = pci_create_root_bus(NULL, NVMEV_PCI_BUS_NUM, &nvmev_pci_ops, NULL,
				  &resources);
	if (!bus) {
		pci_free_resource_list(&resources);
		NVMEV_ERROR("Unable to create PCI bus\n");
		return NULL;
	}

	__attach_nvmev_msi_domain(bus);

	pci_scan_child_bus(bus);
#endif

	if (!bus) {
		NVMEV_ERROR("Unable to create PCI bus\n");
		return NULL;
	}

	/* XXX Only support a singe NVMeVirt instance in the system for now */
	list_for_each_entry(dev, &bus->devices, bus_list) {
		__attach_nvmev_device_msi_domain(dev);
		nvmev_vdev->pdev = dev;
		dev->irq = nvmev_vdev->pcihdr->intr.iline;
#ifdef CONFIG_ARM64
		/*
		 * NVMeVirt performs the virtual device DMA from CPU context. Make
		 * the synthetic PCI function use coherent DMA allocations so the
		 * host NVMe driver's admin queues share normal cacheable memory
		 * attributes with NVMeVirt's direct-map access.
		 */
		dev->dev.dma_coherent = true;
#endif
		__force_nvmev_bar_resource(dev);

		__init_nvme_ctrl_regs(dev);

		nvmev_vdev->old_dbs = kzalloc(PAGE_SIZE, GFP_KERNEL);
		BUG_ON(!nvmev_vdev->old_dbs && "allocating old DBs memory");

		nvmev_vdev->old_bar = kzalloc(PAGE_SIZE, GFP_KERNEL);
		BUG_ON(!nvmev_vdev->old_bar && "allocating old BAR memory");
		memcpy_fromio(nvmev_vdev->old_bar, nvmev_vdev->bar,
			      sizeof(*nvmev_vdev->old_bar));

		nvmev_vdev->msix_table =
			ioremap(nvmev_vdev->config.memmap_start + PAGE_SIZE * 2,
				NR_MAX_IO_QUEUE * PCI_MSIX_ENTRY_SIZE);
		BUG_ON(!nvmev_vdev->msix_table);

		memset_io(nvmev_vdev->msix_table, 0x00,
			  NR_MAX_IO_QUEUE * PCI_MSIX_ENTRY_SIZE);
	}

	NVMEV_INFO("Virtual PCI bus created (node %d)\n", node);

	return bus;
};

struct nvmev_dev *VDEV_INIT(void)
{
	struct nvmev_dev *nvmev_vdev;
	nvmev_vdev = kzalloc(sizeof(*nvmev_vdev), GFP_KERNEL);

	nvmev_vdev->virtDev = kzalloc(PAGE_SIZE, GFP_KERNEL);

	nvmev_vdev->pcihdr = nvmev_vdev->virtDev + OFFS_PCI_HDR;
	nvmev_vdev->pmcap = nvmev_vdev->virtDev + OFFS_PCI_PM_CAP;
	nvmev_vdev->msixcap = nvmev_vdev->virtDev + OFFS_PCI_MSIX_CAP;
	nvmev_vdev->pciecap = nvmev_vdev->virtDev + OFFS_PCIE_CAP;
	nvmev_vdev->extcap = nvmev_vdev->virtDev + OFFS_PCI_EXT_CAP;

	nvmev_vdev->admin_q = NULL;

	return nvmev_vdev;
}

void VDEV_FINALIZE(struct nvmev_dev *nvmev_vdev)
{
	__destroy_nvmev_msi_domain();

	if (nvmev_vdev->msix_table)
		iounmap(nvmev_vdev->msix_table);

	if (nvmev_vdev->bar)
		iounmap(nvmev_vdev->bar);

	if (nvmev_vdev->old_bar)
		kfree(nvmev_vdev->old_bar);

	if (nvmev_vdev->old_dbs)
		kfree(nvmev_vdev->old_dbs);

	if (nvmev_vdev->admin_q) {
		if (nvmev_vdev->admin_q->nvme_cq)
			kfree(nvmev_vdev->admin_q->nvme_cq);

		if (nvmev_vdev->admin_q->nvme_sq)
			kfree(nvmev_vdev->admin_q->nvme_sq);

		kfree(nvmev_vdev->admin_q);
	}

	if (nvmev_vdev->virtDev)
		kfree(nvmev_vdev->virtDev);

	if (nvmev_vdev)
		kfree(nvmev_vdev);
}

static void PCI_HEADER_SETTINGS(struct pci_header *pcihdr, unsigned long base_pa)
{
	pcihdr->id.did = NVMEV_DEVICE_ID;
	pcihdr->id.vid = NVMEV_VENDOR_ID;
	/*
	pcihdr->cmd.id = 1;
	pcihdr->cmd.bme = 1;
	*/
	pcihdr->cmd.mse = 1;
	pcihdr->sts.cl = 1;

	pcihdr->htype.mfd = 0;
	pcihdr->htype.hl = PCI_HEADER_TYPE_NORMAL;

	pcihdr->rid = 0x01;

	pcihdr->cc.bcc = PCI_BASE_CLASS_STORAGE;
	pcihdr->cc.scc = 0x08;
	pcihdr->cc.pi = 0x02;

	pcihdr->mlbar.tp = PCI_BASE_ADDRESS_MEM_TYPE_64 >> 1;
	pcihdr->mlbar.ba = (base_pa & 0xFFFFFFFF) >> 14;

	pcihdr->mulbar = base_pa >> 32;

	pcihdr->ss.ssid = NVMEV_SUBSYSTEM_ID;
	pcihdr->ss.ssvid = NVMEV_SUBSYSTEM_VENDOR_ID;

	pcihdr->erom = 0x0;

	pcihdr->cap = OFFS_PCI_PM_CAP;

	pcihdr->intr.ipin = 0;
	pcihdr->intr.iline = NVMEV_INTX_IRQ;
}

static void PCI_PMCAP_SETTINGS(struct pci_pm_cap *pmcap)
{
	pmcap->pid.cid = PCI_CAP_ID_PM;
	pmcap->pid.next = OFFS_PCI_MSIX_CAP;

	pmcap->pc.vs = 3;
	pmcap->pmcs.nsfrst = 1;
	pmcap->pmcs.ps = PCI_PM_CAP_PME_D0 >> 16;
}

static void PCI_MSIXCAP_SETTINGS(struct pci_msix_cap *msixcap)
{
	msixcap->mxid.cid = PCI_CAP_ID_MSIX;
	msixcap->mxid.next = OFFS_PCIE_CAP;

	msixcap->mxc.mxe = 1;
	msixcap->mxc.ts = 127; // encoded as n-1

	msixcap->mtab.tbir = 0;
	msixcap->mtab.to = 0x400;

	msixcap->mpba.pbao = 0x1000;
	msixcap->mpba.pbir = 0;
}

static void PCI_PCIECAP_SETTINGS(struct pcie_cap *pciecap)
{
	pciecap->pxid.cid = PCI_CAP_ID_EXP;
	pciecap->pxid.next = 0x0;

	pciecap->pxcap.ver = PCI_EXP_FLAGS;
	pciecap->pxcap.imn = 0;
	pciecap->pxcap.dpt = PCI_EXP_TYPE_ENDPOINT;

	pciecap->pxdcap.mps = 1;
	pciecap->pxdcap.pfs = 0;
	pciecap->pxdcap.etfs = 1;
	pciecap->pxdcap.l0sl = 6;
	pciecap->pxdcap.l1l = 2;
	pciecap->pxdcap.rer = 1;
	pciecap->pxdcap.csplv = 0;
	pciecap->pxdcap.cspls = 0;
	pciecap->pxdcap.flrc = 1;
}

static void PCI_EXTCAP_SETTINGS(struct pci_ext_cap *ext_cap)
{
	off_t offset = 0;
	void *ext_cap_base = ext_cap;

	/* AER */
	ext_cap->cid = PCI_EXT_CAP_ID_ERR;
	ext_cap->cver = 1;
	ext_cap->next = PCI_CFG_SPACE_SIZE + 0x50;

	ext_cap = ext_cap_base + 0x50;
	ext_cap->cid = PCI_EXT_CAP_ID_VC;
	ext_cap->cver = 1;
	ext_cap->next = PCI_CFG_SPACE_SIZE + 0x80;

	ext_cap = ext_cap_base + 0x80;
	ext_cap->cid = PCI_EXT_CAP_ID_PWR;
	ext_cap->cver = 1;
	ext_cap->next = PCI_CFG_SPACE_SIZE + 0x90;

	ext_cap = ext_cap_base + 0x90;
	ext_cap->cid = PCI_EXT_CAP_ID_ARI;
	ext_cap->cver = 1;
	ext_cap->next = PCI_CFG_SPACE_SIZE + 0x170;

	ext_cap = ext_cap_base + 0x170;
	ext_cap->cid = PCI_EXT_CAP_ID_DSN;
	ext_cap->cver = 1;
	ext_cap->next = PCI_CFG_SPACE_SIZE + 0x1a0;

	ext_cap = ext_cap_base + 0x1a0;
	ext_cap->cid = PCI_EXT_CAP_ID_SECPCI;
	ext_cap->cver = 1;
	ext_cap->next = 0; 

	/*
	*(ext_cap + 1) = (struct pci_ext_cap) {
		.id = {
			.cid = 0xdead,
			.cver = 0xc,
			.next = 0xafe,
		},
	};

	PCI_CFG_SPACE_SIZE + ...;

	ext_cap = ext_cap + ...;
	ext_cap->id.cid = PCI_EXT_CAP_ID_DVSEC;
	ext_cap->id.cver = 1;
	ext_cap->id.next = 0;
	*/
}

bool NVMEV_PCI_INIT(struct nvmev_dev *nvmev_vdev)
{
	PCI_HEADER_SETTINGS(nvmev_vdev->pcihdr, nvmev_vdev->config.memmap_start);
	PCI_PMCAP_SETTINGS(nvmev_vdev->pmcap);
	PCI_MSIXCAP_SETTINGS(nvmev_vdev->msixcap);
	PCI_PCIECAP_SETTINGS(nvmev_vdev->pciecap);
	PCI_EXTCAP_SETTINGS(nvmev_vdev->extcap);

#if defined(CONFIG_X86) && defined(CONFIG_NVMEV_FAST_X86_IRQ_HANDLING)
	__init_apicid_to_cpuid();
#endif
	nvmev_vdev->intx_disabled = false;

	if (!__init_nvmev_msi_domain())
		return false;

	nvmev_vdev->virt_bus = __create_pci_bus();
	if (!nvmev_vdev->virt_bus) {
		__destroy_nvmev_msi_domain();
		return false;
	}

	return true;
}
