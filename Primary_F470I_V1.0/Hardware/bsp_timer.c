#include "bsp_timer.h"

/* 全局配置实例，显式零初始化 */
timer_irq_config_struct timer2_cfg = {0};

/**
 * @brief  定时器中断初始化，配置定时器更新中断模式
 * @param  timer_cfg: 定时器配置结构体指针
 * @retval none
 */
void bsp_timer_irq_init(timer_irq_config_struct *timer_cfg)
{
    timer_parameter_struct timer_init_struct;
    IRQn_Type irq;

    /* 空指针保护 */
    if(NULL == timer_cfg)
    {
        return;
    }

    /* 先关闭定时器，防止重复初始化异常 */
    timer_disable(timer_cfg->timer_periph);

    /* 1.开启定时器外设时钟 */
    switch(timer_cfg->timer_periph)
    {
        case TIMER0: rcu_periph_clock_enable(RCU_TIMER0); break;
        case TIMER1: rcu_periph_clock_enable(RCU_TIMER1); break;
        case TIMER2: rcu_periph_clock_enable(RCU_TIMER2); break;
        case TIMER3: rcu_periph_clock_enable(RCU_TIMER3); break;
        case TIMER4: rcu_periph_clock_enable(RCU_TIMER4); break;
        case TIMER5: rcu_periph_clock_enable(RCU_TIMER5); break;
        case TIMER6: rcu_periph_clock_enable(RCU_TIMER6); break;
        case TIMER7: rcu_periph_clock_enable(RCU_TIMER7); break;
        case TIMER8: rcu_periph_clock_enable(RCU_TIMER8); break;
        case TIMER9: rcu_periph_clock_enable(RCU_TIMER9); break;
        case TIMER10:rcu_periph_clock_enable(RCU_TIMER10);break;
        case TIMER11:rcu_periph_clock_enable(RCU_TIMER11);break;
        case TIMER12:rcu_periph_clock_enable(RCU_TIMER12);break;
        case TIMER13:rcu_periph_clock_enable(RCU_TIMER13);break;
        default: return;
    }

    /* 2.定时器参数初始化 */
    timer_struct_para_init(&timer_init_struct);
    timer_init_struct.prescaler      = timer_cfg->prescaler;
    timer_init_struct.period         = timer_cfg->period;
    timer_init_struct.alignedmode    = TIMER_COUNTER_EDGE;
    timer_init_struct.counterdirection = TIMER_COUNTER_UP;
    timer_init_struct.clockdivision  = TIMER_CKDIV_DIV1;

    /* 3.装载参数 */
    timer_init(timer_cfg->timer_periph, &timer_init_struct);

    /* 清除更新中断标志，避免未启动定时器就进中断 */
    timer_interrupt_flag_clear(timer_cfg->timer_periph, TIMER_INT_FLAG_UP);
    timer_interrupt_enable(timer_cfg->timer_periph, TIMER_INT_UP);

    /* 5.NVIC中断向量映射 GD32F4xx */
    switch(timer_cfg->timer_periph)
    {
        case TIMER0:  irq = TIMER0_UP_TIMER9_IRQn;       break;
        case TIMER1:  irq = TIMER1_IRQn;                 break;
        case TIMER2:  irq = TIMER2_IRQn;                 break;
        case TIMER3:  irq = TIMER3_IRQn;                 break;
        case TIMER4:  irq = TIMER4_IRQn;                 break;
        case TIMER5:  irq = TIMER5_DAC_IRQn;             break;
        case TIMER6:  irq = TIMER6_IRQn;                 break;
        case TIMER7:  irq = TIMER7_UP_TIMER12_IRQn;      break;
        case TIMER8:  irq = TIMER0_BRK_TIMER8_IRQn;      break;
        case TIMER9:  irq = TIMER0_UP_TIMER9_IRQn;       break;
        case TIMER10: irq = TIMER0_TRG_CMT_TIMER10_IRQn; break;
        case TIMER11: irq = TIMER7_BRK_TIMER11_IRQn;     break;
        case TIMER12: irq = TIMER7_UP_TIMER12_IRQn;      break;
        case TIMER13: irq = TIMER7_TRG_CMT_TIMER13_IRQn; break;
        default: return;
    }
    nvic_irq_enable(irq, timer_cfg->nvic_irq_priority, 0);
}

/**
 * @brief 开启定时器
 */
void bsp_timer_enable(uint32_t timer_periph)
{
    timer_enable(timer_periph);
}

/**
 * @brief 关闭定时器
 */
void bsp_timer_disable(uint32_t timer_periph)
{
    timer_disable(timer_periph);
}

/**
 * @brief 反初始化定时器
 */
void bsp_timer_deinit(uint32_t timer_periph)
{
    timer_disable(timer_periph);
    timer_deinit(timer_periph);
}


/*
GD32F470 总共有 **14 个定时器：TIMER0~TIMER13**

表格

| 类型 | 定时器编号 | 特点 |
| --- | --- | --- |
| 高级定时器（Advanced‑timer） | **TIMER0、TIMER7** | 带互补 PWM 输出、死区生成、刹车 BRK、重复计数器；支持 32 位；可用于电机 FOC、BLDC 驱动 |
| 通用定时器（General‑purpose‑timer） | **TIMER1、TIMER2、TIMER3、TIMER4** | 16 位计数器，输入捕获、输出比较、PWM、正交编码器、从模式；TIMER1/TIMER4 支持 32 位模式；无互补输出 |
| 基本定时器（Basic‑timer） | **TIMER5、TIMER6** | 仅内部计数，只支持更新中断 / DMA，**没有 IO 引脚输出 / 输入**，只能做简单定时、DAC 触发 |
| 通用小型定时器（General‑purpose small timer） | **TIMER8、TIMER9、TIMER10、TIMER11、TIMER12、TIMER13** | 16 位，只有 1‑2 个通道，部分无互补输出；适合简单 PWM、输 |

*/
