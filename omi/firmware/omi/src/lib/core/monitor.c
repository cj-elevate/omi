#include "monitor.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

LOG_MODULE_REGISTER(monitor, CONFIG_LOG_DEFAULT_LEVEL);

static atomic_t cnt_gatt_notify = ATOMIC_INIT(0);
static atomic_t cnt_gatt_notify_fail = ATOMIC_INIT(0);
static atomic_t cnt_mic_buffer = ATOMIC_INIT(0);
static atomic_t cnt_broadcast_audio = ATOMIC_INIT(0);
static atomic_t cnt_broadcast_audio_failed = ATOMIC_INIT(0);
static atomic_t cnt_tx_queue_write = ATOMIC_INIT(0);
static atomic_t cnt_storage_write = ATOMIC_INIT(0);
static atomic_t cnt_sem_timeout = ATOMIC_INIT(0);

int monitor_init(void)
{
    LOG_INF("Monitor system initialized");
    monitor_reset();
    return 0;
}

void monitor_inc_gatt_notify(void)
{
    atomic_inc(&cnt_gatt_notify);
}

void monitor_inc_gatt_notify_fail(void)
{
    atomic_inc(&cnt_gatt_notify_fail);
}

void monitor_inc_mic_buffer(void)
{
    atomic_inc(&cnt_mic_buffer);
}

void monitor_inc_broadcast_audio(void)
{
    atomic_inc(&cnt_broadcast_audio);
}

void monitor_inc_broadcast_audio_failed(void)
{
    atomic_inc(&cnt_broadcast_audio_failed);
}

void monitor_inc_tx_queue_write(void)
{
    atomic_inc(&cnt_tx_queue_write);
}

void monitor_inc_storage_write(void)
{
    atomic_inc(&cnt_storage_write);
}

void monitor_inc_sem_timeout(void)
{
    atomic_inc(&cnt_sem_timeout);
}

static uint16_t atomic_swap_saturated(atomic_t *target)
{
    atomic_val_t val = atomic_set(target, 0);
    return (val > UINT16_MAX) ? UINT16_MAX : (uint16_t)val;
}

void monitor_snapshot_and_reset(struct monitor_snapshot *out)
{
    out->gatt_notify = atomic_swap_saturated(&cnt_gatt_notify);
    out->gatt_notify_fail = atomic_swap_saturated(&cnt_gatt_notify_fail);
    out->broadcast_audio = atomic_swap_saturated(&cnt_broadcast_audio);
    out->broadcast_audio_failed = atomic_swap_saturated(&cnt_broadcast_audio_failed);
    out->tx_queue_write = atomic_swap_saturated(&cnt_tx_queue_write);
    out->sem_timeout = atomic_swap_saturated(&cnt_sem_timeout);
}

void monitor_log_metrics(void)
{
    LOG_INF("Metrics: Mic=%u GATT=%u/%u Bcast=%u/%u TxQ=%u Sto=%u Sem=%u",
            (unsigned)atomic_get(&cnt_mic_buffer),
            (unsigned)atomic_get(&cnt_gatt_notify),
            (unsigned)atomic_get(&cnt_gatt_notify_fail),
            (unsigned)atomic_get(&cnt_broadcast_audio),
            (unsigned)atomic_get(&cnt_broadcast_audio_failed),
            (unsigned)atomic_get(&cnt_tx_queue_write),
            (unsigned)atomic_get(&cnt_storage_write),
            (unsigned)atomic_get(&cnt_sem_timeout));
}

void monitor_reset(void)
{
    atomic_set(&cnt_gatt_notify, 0);
    atomic_set(&cnt_gatt_notify_fail, 0);
    atomic_set(&cnt_mic_buffer, 0);
    atomic_set(&cnt_broadcast_audio, 0);
    atomic_set(&cnt_broadcast_audio_failed, 0);
    atomic_set(&cnt_tx_queue_write, 0);
    atomic_set(&cnt_storage_write, 0);
    atomic_set(&cnt_sem_timeout, 0);
    LOG_DBG("All metrics reset");
}
