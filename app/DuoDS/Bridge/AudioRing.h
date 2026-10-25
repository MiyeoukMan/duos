// AudioRing — 에뮬레이션 스레드(쓰기 하나)와 오디오 렌더 스레드(읽기 하나) 사이의 잠금 없는 링 버퍼.
// 16비트 스테레오 프레임 단위. 렌더 콜백에서 불러도 되도록 할당 · 잠금이 없다.

#ifndef AUDIORING_H
#define AUDIORING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AudioRing AudioRing;

AudioRing* audio_ring_create(int capacity_frames);
void audio_ring_destroy(AudioRing* ring);
void audio_ring_clear(AudioRing* ring);          // 쓰는 쪽에서만(읽는 쪽이 멈춰 있을 때)
int audio_ring_available(const AudioRing* ring); // 쌓인 프레임 수
// 넣은 프레임 수를 돌려준다(가득 차면 넘치는 것은 버린다).
int audio_ring_write(AudioRing* ring, const int16_t* frames, int count);
// 왼 · 오를 따로 float로 꺼낸다(0 ~ 1 음량을 곱해서). 모자라면 마지막 값에서 0으로 줄여 채운다. 꺼낸 프레임 수를 돌려준다.
int audio_ring_read_float(AudioRing* ring, float* left, float* right, int count, float volume);

#ifdef __cplusplus
}
#endif

#endif
