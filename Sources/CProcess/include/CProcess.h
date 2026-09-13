#ifndef LM15_CPROCESS_H
#define LM15_CPROCESS_H
#include <stddef.h>
// The small OS shim runs credential helpers without a shell and owns their process group.
typedef struct lm15_process lm15_process;
lm15_process *lm15_process_create(void);
void lm15_process_cancel(lm15_process *process);
void lm15_process_destroy(lm15_process *process);
int lm15_process_run(lm15_process *process, const char *executable, char *const argv[], char *const envp[], int timeout_ms, unsigned char *output, size_t capacity, size_t *length);
#endif
