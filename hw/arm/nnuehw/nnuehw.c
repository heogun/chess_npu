// SPDX-License-Identifier: GPL-2.0
/*
 * nnuehw.c — NNUE 가속기 UIO 드라이버 (DE1-SoC)
 *
 * 노출:
 *  - /dev/uio0  : 표준 UIO 장치 — mmap(map 0 = 전체 창) + read(완료 IRQ 대기)
 *  - /dev/nnuehw: misc 디바이스 — ioctl (START/STOP/RESET/SET_BATCH/GET_STATUS)
 *
 * FPGA-Top RTL이 lw bridge 상 NNUEHW_WINDOW_SIZE 연속 창으로 구현되고
 * 완료 IRQ를 연결한다고 가정. 물리주소/IRQ는 DT 'reg'/'interrupts' 로 공급.
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/uio_driver.h>
#include <linux/interrupt.h>
#include <linux/of.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/uaccess.h>
#include <linux/miscdevice.h>
#include <linux/wait.h>
#include <linux/mutex.h>

#include "nnuehw.h"

struct nnuehw_dev {
    struct uio_info     info;
    struct miscdevice   misc;
    struct platform_device *pdev;
    void __iomem       *win;
    resource_size_t     phys;
    size_t              size;
    u32                 batch;
    unsigned int        irq;
    wait_queue_head_t   wq;
};

static struct nnuehw_dev *g_dev;

static u32 nnuehw_rd(struct nnuehw_dev *d, u32 off) { return ioread32(d->win + off / 4); }
static void nnuehw_wr(struct nnuehw_dev *d, u32 off, u32 v) { iowrite32(v, d->win + off / 4); }

static int nnuehw_misc_open(struct inode *inode, struct file *filp)
{
    filp->private_data = g_dev;
    return 0;
}

static long nnuehw_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct nnuehw_dev *d = filp->private_data;
    void __user *uarg   = (void __user *)arg;

    switch (cmd) {
    case NNUEHW_IOC_RESET:
        nnuehw_wr(d, NNUEHW_CSR_CONTROL, NNUEHW_CTRL_RESET);
        nnuehw_wr(d, NNUEHW_CSR_CONTROL, 0);
        break;
    case NNUEHW_IOC_START:
        nnuehw_wr(d, NNUEHW_CSR_CONTROL,
                  nnuehw_rd(d, NNUEHW_CSR_CONTROL) | NNUEHW_CTRL_START);
        break;
    case NNUEHW_IOC_STOP:
        nnuehw_wr(d, NNUEHW_CSR_CONTROL,
                  nnuehw_rd(d, NNUEHW_CSR_CONTROL) & ~NNUEHW_CTRL_START);
        break;
    case NNUEHW_IOC_SET_BATCH: {
        u32 b;
        if (copy_from_user(&b, uarg, sizeof(b)))
            return -EFAULT;
        d->batch = b;
        break;
    }
    case NNUEHW_IOC_GET_STATUS: {
        struct nnuehw_status st = {
            .version     = nnuehw_rd(d, NNUEHW_CSR_VERSION),
            .control     = nnuehw_rd(d, NNUEHW_CSR_CONTROL),
            .status      = nnuehw_rd(d, NNUEHW_CSR_STATUS),
            .desc_head   = nnuehw_rd(d, NNUEHW_CSR_DESC_HEAD),
            .desc_tail   = nnuehw_rd(d, NNUEHW_CSR_DESC_TAIL),
            .result_head = nnuehw_rd(d, NNUEHW_CSR_RESULT_HEAD),
            .result_tail = nnuehw_rd(d, NNUEHW_CSR_RESULT_TAIL),
            .done        = nnuehw_rd(d, NNUEHW_CSR_DONE),
            .irq_status  = nnuehw_rd(d, NNUEHW_CSR_IRQ_STATUS),
            .batch_size  = d->batch,
        };
        if (copy_to_user(uarg, &st, sizeof(st)))
            return -EFAULT;
        break;
    }
    default:
        return -ENOTTY;
    }
    return 0;
}

static const struct file_operations nnuehw_misc_fops = {
    .owner          = THIS_MODULE,
    .open           = nnuehw_misc_open,
    .unlocked_ioctl = nnuehw_ioctl,
};

static irqreturn_t nnuehw_irq(int irq, void *ctx)
{
    struct nnuehw_dev *d = ctx;
    u32 irq_st = nnuehw_rd(d, NNUEHW_CSR_IRQ_STATUS);

    if (!(irq_st & NNUEHW_IRQ_RESULT_AVAIL))
        return IRQ_NONE;
    uio_event_notify(&d->info);
    wake_up_interruptible(&d->wq);
    return IRQ_HANDLED;
}

static int nnuehw_probe(struct platform_device *pdev)
{
    struct resource *res;
    struct nnuehw_dev *d;
    int ret;

    d = devm_kzalloc(&pdev->dev, sizeof(*d), GFP_KERNEL);
    if (!d)
        return -ENOMEM;
    init_waitqueue_head(&d->wq);
    d->pdev = pdev;

    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    if (!res)
        return -ENODEV;
    d->phys = res->start;
    d->size = resource_size(res);
    d->win  = devm_ioremap(&pdev->dev, d->phys, d->size);
    if (!d->win)
        return -ENOMEM;

    d->irq = platform_get_irq(pdev, 0);
    if (d->irq < 0)
        return d->irq;

    d->info.name    = NNUEHW_DEVNAME;
    d->info.version = "1.0";
    d->info.irq     = d->irq;
    d->info.mem[0].name    = "nnuehw-window";
    d->info.mem[0].addr    = d->phys;
    d->info.mem[0].size    = d->size;
    d->info.mem[0].memtype = UIO_MEM_PHYS;

    ret = devm_request_irq(&pdev->dev, d->irq, nnuehw_irq,
                           IRQF_SHARED, "nnuehw", d);
    if (ret)
        return ret;

    d->batch = 64;
    platform_set_drvdata(pdev, d);

    ret = uio_register_device(&pdev->dev, &d->info);
    if (ret)
        return ret;

    d->misc.name  = NNUEHW_DEVNAME;
    d->misc.minor = MISC_DYNAMIC_MINOR;
    d->misc.fops  = &nnuehw_misc_fops;
    ret = misc_register(&d->misc);
    if (ret) {
        uio_unregister_device(&d->info);
        return ret;
    }

    g_dev = d;
    dev_info(&pdev->dev, "nnuehw @ %pa (size %zu), irq %u\n",
             &d->phys, d->size, d->irq);
    return 0;
}

static void nnuehw_remove(struct platform_device *pdev)
{
    struct nnuehw_dev *d = platform_get_drvdata(pdev);

    misc_deregister(&d->misc);
    uio_unregister_device(&d->info);
    g_dev = NULL;
}

static const struct of_device_id nnuehw_of_match[] = {
    { .compatible = NNUEHW_DT_COMPAT, },
    { },
};
MODULE_DEVICE_TABLE(of, nnuehw_of_match);

static struct platform_driver nnuehw_driver = {
    .driver = {
        .name           = NNUEHW_DEVNAME,
        .of_match_table = nnuehw_of_match,
    },
    .probe  = nnuehw_probe,
    .remove = nnuehw_remove,
};
module_platform_driver(nnuehw_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("chess_npu");
MODULE_DESCRIPTION("NNUE accelerator UIO device (DE1-SoC)");