#ifndef REDIWM_PRINT_DIRECT_H
#define REDIWM_PRINT_DIRECT_H
struct rediwm_cups;
struct rediwm_cups *rediwm_cups_create(void);
void rediwm_cups_destroy(struct rediwm_cups *);
int rediwm_cups_fd(struct rediwm_cups *);
/* All commands and results are copied. state: 0 working, 1 password, 2 done. */
int rediwm_cups_submit(struct rediwm_cups *, const char *, int, const char *const *, int);
int rediwm_cups_state(struct rediwm_cups *);
int rediwm_cups_result(struct rediwm_cups *);
void rediwm_cups_credentials(struct rediwm_cups *, const char *, const char *, unsigned long);
void rediwm_cups_cancel(struct rediwm_cups *);
void rediwm_cups_finish(struct rediwm_cups *);
const char *rediwm_cups_device(struct rediwm_cups *, int, int);
#endif
