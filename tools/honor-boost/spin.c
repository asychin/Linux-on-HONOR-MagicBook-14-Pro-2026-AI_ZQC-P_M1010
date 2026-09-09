/*
 * spin.c — all-core AVX/FMA load for RAPL power-cap measurement.
 *
 * One thread per online CPU, each in a tight fused-multiply-add loop so the
 * load is dense enough to actually request more than the ~50 W EC cap.  Runs
 * until killed.  Build: gcc -O3 -march=native -pthread -o spin spin.c -lm
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile double sink;
static volatile int running = 1;

static void *worker(void *arg)
{
    (void)arg;
    int cpu = (int)(intptr_t)arg;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);

    while (running) {
        /* 8 independent FMAs to keep the FPU busy */
        __asm__ volatile(
            "vfmadd132pd %%ymm0, %%ymm1, %%ymm2\n\t"
            "vfmadd132pd %%ymm3, %%ymm4, %%ymm5\n\t"
            "vfmadd132pd %%ymm6, %%ymm7, %%ymm8\n\t"
            "vfmadd132pd %%ymm9, %%ymm10, %%ymm11\n\t"
            :
            :
            : "ymm0", "ymm1", "ymm2", "ymm3", "ymm4", "ymm5",
              "ymm6", "ymm7", "ymm8", "ymm9", "ymm10", "ymm11");
        sink = 1.0;
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

    printf("spinning %ld threads; Ctrl-C to stop\n", n);
    fflush(stdout);
    pause();

    running = 0;
    for (long i = 0; i < n; i++)
        pthread_join(t[i], NULL);
    free(t);
    return 0;
}
