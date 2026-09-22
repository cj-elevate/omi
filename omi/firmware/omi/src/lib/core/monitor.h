#ifndef MONITOR_H
#define MONITOR_H

#include <stdbool.h>
#include <stdint.h>

int monitor_init(void);

void monitor_inc_gatt_notify(void);
void monitor_inc_gatt_notify_fail(void);
void monitor_inc_mic_buffer(void);
void monitor_inc_broadcast_audio(void);
void monitor_inc_broadcast_audio_failed(void);
void monitor_inc_tx_queue_write(void);
void monitor_inc_storage_write(void);
void monitor_inc_sem_timeout(void);

struct monitor_snapshot {
    uint16_t gatt_notify;
    uint16_t gatt_notify_fail;
    uint16_t broadcast_audio;
    uint16_t broadcast_audio_failed;
    uint16_t tx_queue_write;
    uint16_t sem_timeout;
};

/* Atomically read and reset counters, returning deltas since last call.
 * Values saturate at UINT16_MAX. */
void monitor_snapshot_and_reset(struct monitor_snapshot *out);

void monitor_log_metrics(void);
void monitor_reset(void);

#endif // MONITOR_H
