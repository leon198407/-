#ifndef __BSP_TIMER_H
#define __BSP_TIMER_H

#include "gd32f4xx.h"

/* ��ʱ����ʼ���ṹ�壬��ʱ�ж�ģʽ */
typedef struct
{
    uint32_t timer_periph;      /* TIMERx: TIMER0~TIMER13 */
    uint16_t prescaler;         /* Ԥ��Ƶ 0~65535 */
    uint32_t period;            /* �Զ���װ��ֵ */
    uint8_t nvic_irq_priority;  /* �ж����ȼ� */
}timer_irq_config_struct;

/* 全局配置实例，供 main.c 等外部直接使用 */
extern timer_irq_config_struct timer2_cfg;

/* 函数声明 */
void bsp_timer_irq_init(timer_irq_config_struct *timer_cfg);
void bsp_timer_enable(uint32_t timer_periph);
void bsp_timer_disable(uint32_t timer_periph);
void bsp_timer_deinit(uint32_t timer_periph);

#endif
