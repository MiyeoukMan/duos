#include "AudioRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct AudioRing
{
    int16_t* data;          // capacity × 2
    int capacity;           // 2의 거듭제곱
    _Atomic int head;       // 다음에 쓸 자리(쓰는 쪽만 바꾼다)
    _Atomic int tail;       // 다음에 읽을 자리(읽는 쪽만 바꾼다)
    float lastL, lastR;     // 모자랄 때 끊기는 소리 대신 줄여 가는 값(읽는 쪽 것)
};

AudioRing* audio_ring_create(int capacity_frames)
{
    int cap = 1;
    while (cap < capacity_frames) cap <<= 1;
    AudioRing* r = calloc(1, sizeof(AudioRing));
    r->data = calloc((size_t)cap * 2, sizeof(int16_t));
    r->capacity = cap;
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return r;
}

void audio_ring_destroy(AudioRing* ring)
{
    if (!ring) return;
    free(ring->data);
    free(ring);
}

void audio_ring_clear(AudioRing* ring)
{
    atomic_store(&ring->tail, atomic_load(&ring->head));
}

int audio_ring_available(const AudioRing* ring)
{
    int h = atomic_load_explicit(&((AudioRing*)ring)->head, memory_order_acquire);
    int t = atomic_load_explicit(&((AudioRing*)ring)->tail, memory_order_acquire);
    return (h - t) & (ring->capacity - 1);
}

int audio_ring_write(AudioRing* ring, const int16_t* frames, int count)
{
    int mask = ring->capacity - 1;
    int h = atomic_load_explicit(&ring->head, memory_order_relaxed);
    int t = atomic_load_explicit(&ring->tail, memory_order_acquire);
    int space = ring->capacity - 1 - ((h - t) & mask);
    if (count > space) count = space;
    for (int i = 0; i < count; i++)
    {
        int at = (h + i) & mask;
        ring->data[at * 2] = frames[i * 2];
        ring->data[at * 2 + 1] = frames[i * 2 + 1];
    }
    atomic_store_explicit(&ring->head, (h + count) & mask, memory_order_release);
    return count;
}

int audio_ring_read_float(AudioRing* ring, float* left, float* right, int count, float volume)
{
    int mask = ring->capacity - 1;
    int t = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    int h = atomic_load_explicit(&ring->head, memory_order_acquire);
    int avail = (h - t) & mask;
    int n = count < avail ? count : avail;
    const float k = volume / 32768.f;
    for (int i = 0; i < n; i++)
    {
        int at = (t + i) & mask;
        left[i] = ring->data[at * 2] * k;
        right[i] = ring->data[at * 2 + 1] * k;
    }
    if (n > 0)
    {
        ring->lastL = left[n - 1];
        ring->lastR = right[n - 1];
    }
    for (int i = n; i < count; i++)
    {
        ring->lastL *= 0.995f;
        ring->lastR *= 0.995f;
        left[i] = ring->lastL;
        right[i] = ring->lastR;
    }
    atomic_store_explicit(&ring->tail, (t + n) & mask, memory_order_release);
    return n;
}
