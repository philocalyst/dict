#ifndef WORD_CONSTRUCTIONS_PREPARED_JOBS_H
#define WORD_CONSTRUCTIONS_PREPARED_JOBS_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// The caller keeps frame bytes alive until wpg_close. Return zero on success.
int wpg_prepare(const unsigned char *frame, size_t frame_len, void **out_handle);
void wpg_close(void *handle);
int wpg_stats(void *handle, size_t *total, size_t *jobs,
              size_t *model_reserved, size_t *job_directory);
// Total live decoder arena and Job-directory requests, with a strict 512 MiB
// cap. These numbers exclude the caller-owned encoded frame and output buffer.
int wpg_budget_stats(void *handle, size_t *live, size_t *peak, size_t *limit);
int wpg_read(void *handle, size_t start, size_t length,
             unsigned char *output, size_t output_capacity, size_t *jobs);
#ifdef __cplusplus
}
#endif
#endif
