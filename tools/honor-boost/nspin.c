/*
 * nspin.c — non-AVX all-core load for RAPL power-cap measurement.
 *
 * Unlike spin.c (AVX FMA, which triggers the AVX downclock and only draws
 * ~35 W), this uses a serial chain of integer ops that cannot be vectorized,
 * so the cores run at their normal high turbo and draw more power.  One thread
 * per online CPU, until killed.
 *
 *   gcc -O2 -pthread -o nspin nspin.c
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile uint64_t sink;
static volatile int running = 1;

static void *worker(void *arg)
{
    int cpu = (int)(intptr_t)arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);

    uint64_t x = 0x9e3779b97f4a7c15ULL ^ (uint64_t)cpu;
    while (running) {
        for (int i = 0; i < 2000; i++) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x = x * 0x2545F4914F6CDD1DULL + 1;
        }
        sink = x;
    }
    return NULL;
}

int main(void)
{
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    pthread_t *t = calloc((size_t)n, sizeof(*t));
    if (!t) return 1;
    for (long i = 0; i < n; i++)
        pthread_create(&t[i], NULL, worker, (void *)(intptr_t)i);
    printf("nspin: %ld threads; Ctrl-C to stop\n", n);
    fflush(stdout);
    pause();
    running = 0;
    for (long i = 0; i < n; i++)
        pthread_join(t[i], NULL);
    free(t);
    return 0;
}
