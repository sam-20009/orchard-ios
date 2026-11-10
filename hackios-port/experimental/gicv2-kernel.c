/*
 * Experimental GICv2 interrupt backend for HakiOS's generic arm64 port.
 * Compiled only when GENERIC_GIC_V2_IRQ is enabled.
 * IMPORTANT: QEMU "virt" proof only; Exynos MMIO/firmware not validated.
 *
 * The existing HakiOS platform calls gic_v3_irq_* by name; this file
 * deliberately exports the identical interface, backed by GICv2 registers.
 */
#define GIC2D_CTLR             0x000
#define GIC2D_IGROUPR(n)       (0x080u + 4u * (n))
#define GIC2D_ISENABLER(n)     (0x100u + 4u * (n))
#define GIC2D_ICENABLER(n)     (0x180u + 4u * (n))
#define GIC2D_ICPENDR(n)       (0x280u + 4u * (n))
#define GIC2D_ICACTIVER(n)     (0x380u + 4u * (n))
#define GIC2D_IPRIORITYR(n)    (0x400u + (n))
#define GIC2D_ITARGETSR(n)     (0x800u + (n))
#define GIC2D_ICFGR(n)         (0xc00u + 4u * (n))
#define GIC2D_SGIR             0xf00
#define GIC2C_CTLR             0x000
#define GIC2C_PMR              0x004
#define GIC2C_BPR              0x008
#define GIC2C_IAR              0x00c
#define GIC2C_EOIR             0x010
#define GIC2_TIMER_ID          27u
#define GIC2_SGI_SIGNAL        0u
#define GIC2_SGI_STOP          1u
#define GIC2_SPURIOUS          1020u
#define GIC2_MAX_SPIS          48u
#define GIC2_PRIORITY          0xa0u

static vm_offset_t gic2_dist, gic2_cpu;
static uint32_t gic2_active[MAX_CPUS];
static decl_simple_lock_data(, gic2_spi_lock);
uint64_t gic_unhandled_count;
uint32_t gic_last_unhandled;
struct gic2_spi {
    uint32_t intid;
    void (*handler)(void *, uint32_t);
    void *context;
    uint32_t busy;
    uint64_t count;
};
static struct gic2_spi gic2_spis[GIC2_MAX_SPIS];

static inline uint32_t
gic2_read(vm_offset_t addr) { return *(volatile uint32_t *)addr; }
static inline void
gic2_write(vm_offset_t addr, uint32_t val) { *(volatile uint32_t *)addr = val; }
static void
gic2_mask(uint32_t n) {
    gic2_write(gic2_dist + GIC2D_ICENABLER(n / 32), 1u << (n % 32));
}
static void
gic2_unmask(uint32_t n) {
    gic2_write(gic2_dist + GIC2D_ISENABLER(n / 32), 1u << (n % 32));
}
void
gic_v3_spi_mask(uint32_t n) {
    if (gic2_dist && n >= 32 && n < GIC2_SPURIOUS) gic2_mask(n);
}
void
gic_v3_spi_unmask(uint32_t n) {
    if (gic2_dist && n >= 32 && n < GIC2_SPURIOUS) gic2_unmask(n);
}
static bool
gic2_handle_spi(uint32_t n) {
    for (unsigned i=0;i<GIC2_MAX_SPIS;i++) {
        struct gic2_spi *s=&gic2_spis[i];
        if (os_atomic_load(&s->intid, acquire) == n) {
            os_atomic_inc(&s->busy, acquire);
            if (os_atomic_load(&s->intid, relaxed)==n) {
                s->count++;
                s->handler(s->context, n);
            }
            os_atomic_dec(&s->busy, release);
            return true;
        }
    }
    return false;
}
kern_return_t
gic_v3_spi_attach(uint32_t n, bool edge, void (*handler)(void*,uint32_t), void *context) {
    if (!gic2_dist || n < 32 || n >= GIC2_SPURIOUS || handler == NULL)
        return KERN_INVALID_ARGUMENT;
    simple_lock(&gic2_spi_lock, LCK_GRP_NULL);
    struct gic2_spi *empty=NULL;
    for (unsigned i=0;i<GIC2_MAX_SPIS;i++) {
        if (gic2_spis[i].intid==n) {
            simple_unlock(&gic2_spi_lock);
            return KERN_NAME_EXISTS;
        }
        if (!empty && !gic2_spis[i].intid && !gic2_spis[i].busy)
            empty=&gic2_spis[i];
    }
    if (!empty) {
        simple_unlock(&gic2_spi_lock);
        return KERN_RESOURCE_SHORTAGE;
    }
    empty->handler=handler;
    empty->context=context;
    empty->count=0;
    os_atomic_store(&empty->intid, n, release);
    simple_unlock(&gic2_spi_lock);
    gic2_mask(n);
    gic2_write(gic2_dist + GIC2D_ICPENDR(n/32),1u<<(n%32));
    uint32_t cfg=gic2_read(gic2_dist+GIC2D_ICFGR(n/16));
    cfg &= ~(3u<<((n%16)*2));
    if (edge) cfg |= 2u<<((n%16)*2);
    gic2_write(gic2_dist+GIC2D_ICFGR(n/16),cfg);
    *(volatile uint8_t *)(gic2_dist+GIC2D_IPRIORITYR(n))=GIC2_PRIORITY;
    /* Initial research is deliberately uniprocessor. */
    *(volatile uint8_t *)(gic2_dist+GIC2D_ITARGETSR(n))=1;
    gic2_unmask(n);
    return KERN_SUCCESS;
}
void
gic_v3_spi_detach(uint32_t n) {
    if (!gic2_dist || n < 32 || n >= GIC2_SPURIOUS) return;
    gic2_mask(n);
    gic2_write(gic2_dist + GIC2D_ICPENDR(n/32),1u<<(n%32));
    for (unsigned i=0;i<GIC2_MAX_SPIS;i++) {
        struct gic2_spi *s=&gic2_spis[i];
        if (s->intid==n) {
            os_atomic_store(&s->intid,0,release);
            while (os_atomic_load(&s->busy,acquire)) {}
        }
    }
}
uint64_t
gic_v3_spi_count(uint32_t n) {
    for (unsigned i=0;i<GIC2_MAX_SPIS;i++)
        if (gic2_spis[i].intid==n) return gic2_spis[i].count;
    return 0;
}
void
gic_v3_irq_signal(uint32_t phys_id) {
    if (gic2_dist) gic2_write(gic2_dist+GIC2D_SGIR,
         (1u << (16u+(phys_id & 7u))) | GIC2_SGI_SIGNAL);
}
void
gic_v3_irq_signal_stop(uint32_t phys_id) {
    if (gic2_dist) gic2_write(gic2_dist+GIC2D_SGIR,
         (1u << (16u+(phys_id & 7u))) | GIC2_SGI_STOP);
}
static void
gic2_irq_handler(__unused void *target, __unused void *refcon,
                 __unused void *nub, __unused int source) {
    for (;;) {
        uint32_t iar=gic2_read(gic2_cpu+GIC2C_IAR);
        uint32_t intid=iar & 0x3ff;
        if (intid>=GIC2_SPURIOUS) break;
        gic2_active[cpu_number()]=iar+1;
        if (intid==GIC2_TIMER_ID) {
            getCpuDatap()->cpu_decrementer=-1;
            rtclock_intr(TRUE);
        } else if (intid==GIC2_SGI_SIGNAL) {
            cpu_signal_handler();
        } else if (intid==GIC2_SGI_STOP) {
            psci_smp_stop_here();
        } else if (intid>=32 && gic2_handle_spi(intid)) {
            /* handled */
        } else {
            gic2_mask(intid);
            gic_unhandled_count++;
            gic_last_unhandled=intid;
        }
        gic2_write(gic2_cpu+GIC2C_EOIR,iar);
        gic2_active[cpu_number()]=0;
    }
}
void
gic_v3_irq_quiesce(void) {
    if (!gic2_dist) return;
    for(unsigned i=0;i<GIC2_MAX_SPIS;i++)
        if(gic2_spis[i].intid) gic2_mask(gic2_spis[i].intid);
    uint32_t iar_plus=gic2_active[cpu_number()];
    if (iar_plus)
        gic2_write(gic2_cpu+GIC2C_EOIR,iar_plus-1);
    gic2_active[cpu_number()]=0;
}
void
gic_v3_irq_cpu_shutdown(void) {
    if(!gic2_dist) return;
    gic_v3_irq_quiesce();
    gic2_write(gic2_cpu+GIC2C_CTLR,0);
}
void
gic_v3_irq_cpu_init(void) {
    if (!gic2_dist) {
        DTEntry entry;
        void const *prop;
        unsigned int len;
        if (SecureDTLookupEntry(NULL,"/arm-io/gic",&entry)!=kSuccess ||
            SecureDTGetProperty(entry,"reg",&prop,&len)!=kSuccess ||
            len < 4*sizeof(uint64_t))
            panic("gic2: no /arm-io/gic register map");
        uint64_t const *reg=(uint64_t const *)prop;
        vm_offset_t base=pe_arm_get_soc_base_phys();
        simple_lock_init(&gic2_spi_lock,0);
        gic2_dist=ml_io_map(base+reg[0],reg[1]);
        gic2_cpu=ml_io_map(base+reg[2],reg[3]);
        if(!gic2_dist || !gic2_cpu)
            panic("gic2: cannot map distributor or cpu interface");
    }
    /* Only core 0 until affinity/EL/handoff have been validated. */
    if(cpu_number()!=0) panic("gic2: CPU >0 disabled during bring-up");
    uint32_t mine=1u<<GIC2_TIMER_ID;
    gic2_write(gic2_dist+GIC2D_IGROUPR(0),
        gic2_read(gic2_dist+GIC2D_IGROUPR(0))|mine);
    *(volatile uint8_t *)(gic2_dist+GIC2D_IPRIORITYR(GIC2_TIMER_ID))
        =GIC2_PRIORITY;
    gic2_write(gic2_dist+GIC2D_ISENABLER(0),mine);
    gic2_write(gic2_dist+GIC2D_CTLR,
        gic2_read(gic2_dist+GIC2D_CTLR)|2u);
    gic2_write(gic2_cpu+GIC2C_PMR,0xff);
    gic2_write(gic2_cpu+GIC2C_BPR,0);
    gic2_write(gic2_cpu+GIC2C_CTLR,2u);
    ml_install_interrupt_handler(NULL,0,NULL,gic2_irq_handler,NULL);
    kprintf("gic2: distributor %p, CPU interface %p, timer PPI %u\n",
        (void *)gic2_dist,(void *)gic2_cpu,GIC2_TIMER_ID);
}
