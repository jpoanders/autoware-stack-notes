/* fi3_delay_shim.c — FI3 publication delay, LD_PRELOAD shim on Cyclone's dds_write.
 *
 * Interposes dds_create_topic_sertype (to learn each topic's sertype; Cyclone 0.10 has
 * no public getter) and dds_write. Writes on FI3_TOPIC are serialized at call time
 * (stamp + value as measured), queued, and released later by one sender thread via
 * the real dds_writecdr. Everything else passes straight through. See ../PLAN.md.
 *
 * Env (read once): FI3_TOPIC, FI3_MODE=off|probe|fixed|jitter|stall|stretch,
 * FI3_DELAY_MS, FI3_JITTER_MS, FI3_STALL_MS, FI3_STALL_POLICY=flush|latest,
 * FI3_RATE_HZ, FI3_START_S, FI3_DURATION_S, FI3_QUEUE_MAX, FI3_LOG.
 *
 * Not linked against ddsc: libddsc may be dlopen'ed RTLD_LOCAL (rcutils, Unity), so
 * every ddsc call goes through a pointer resolved by real().
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "dds/dds.h"
#include "dds/ddsi/ddsi_sertype.h"
#include "dds/ddsi/ddsi_serdata.h"

enum mode { M_OFF, M_PROBE, M_FIXED, M_JITTER, M_STALL, M_STRETCH };

typedef dds_entity_t (*create_topic_fn)(dds_entity_t, const char *, struct ddsi_sertype **,
                                        const dds_qos_t *, const dds_listener_t *,
                                        const struct ddsi_plist *);
typedef dds_return_t (*write_fn)(dds_entity_t, const void *);
typedef dds_return_t (*writecdr_fn)(dds_entity_t, struct ddsi_serdata *);
typedef dds_entity_t (*get_topic_fn)(dds_entity_t);

static create_topic_fn real_create_topic;
static write_fn real_write;
static writecdr_fn real_writecdr;
static get_topic_fn real_get_topic;

/* config */
static enum mode mode;
static const char *topic_name;
static int64_t delay_ns, jitter_ns, stall_ns, period_ns, start_ns, dur_ns;
static int stall_latest;
static size_t qmax;
static FILE *logf;

/* target topics (the same name can be created once per participant) */
#define MAX_TARGETS 16
static struct { dds_entity_t tp; const struct ddsi_sertype *st; } targets[MAX_TARGETS];
static int ntargets;

/* FIFO queue, guarded by mu */
struct item { dds_entity_t wr; struct ddsi_serdata *d; uint64_t seq; int64_t t_in, t_in_wall, t_rel; };
static struct item *q;
static size_t qhead, qlen;
static uint64_t seq;
static int64_t t_first = -1, last_rel;
static unsigned rnd = 1;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static int64_t now_ns(clockid_t c) {
  struct timespec ts; clock_gettime(c, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void *real(const char *sym) {
  void *p = dlsym(RTLD_NEXT, sym);
  if (!p) {
    void *h = dlopen("libddsc.so.0", RTLD_NOLOAD | RTLD_LAZY);
    if (h) p = dlsym(h, sym);
  }
  return p;
}

static void resolve(void) {
  /* libddsc may load after the first hook call into it; retry until found */
  if (!real_create_topic) real_create_topic = (create_topic_fn)real("dds_create_topic_sertype");
  if (!real_write) real_write = (write_fn)real("dds_write");
  if (!real_writecdr) real_writecdr = (writecdr_fn)real("dds_writecdr");
  if (!real_get_topic) real_get_topic = (get_topic_fn)real("dds_get_topic");
}

/* caller holds mu (or is single-threaded init) */
static void logln(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logln(const char *fmt, ...) {
  if (!logf) return;
  va_list ap; va_start(ap, fmt); vfprintf(logf, fmt, ap); va_end(ap);
  fputc('\n', logf); fflush(logf);
}

static double envf(const char *k, double dflt) { const char *v = getenv(k); return v ? atof(v) : dflt; }

static void free_serdata(struct ddsi_serdata *d) {
  ddsi_serdata_unref(d);   /* header-inline: atomic dec + d->ops->free, no ddsc symbol */
}

static void log_item(const struct item *it, int64_t t_out_wall, const char *action) {
  logln("%s %llu %lld %lld %.3f %s", topic_name, (unsigned long long)it->seq,
        (long long)it->t_in_wall, (long long)t_out_wall,
        t_out_wall ? (t_out_wall - it->t_in_wall) / 1e6 : 0.0, action);
}

static void *sender(void *arg) {
  (void)arg;
  pthread_mutex_lock(&mu);
  for (;;) {
    while (qlen == 0) pthread_cond_wait(&cv, &mu);
    struct item it = q[qhead];
    if (now_ns(CLOCK_MONOTONIC) < it.t_rel) {
      struct timespec ts = { it.t_rel / 1000000000, it.t_rel % 1000000000 };
      pthread_cond_timedwait(&cv, &mu, &ts);   /* re-check: head may have been replaced */
      continue;
    }
    qhead = (qhead + 1) % qmax; qlen--;
    pthread_mutex_unlock(&mu);
    dds_return_t rc = real_writecdr(it.wr, it.d);
    int64_t t_out = now_ns(CLOCK_REALTIME);
    if (rc < 0) free_serdata(it.d);            /* not consumed on writer-lock failure */
    pthread_mutex_lock(&mu);
    log_item(&it, t_out, rc < 0 ? "fail" : "sent");
  }
  return NULL;
}

static void init(void) {
  resolve();
  const char *m = getenv("FI3_MODE");
  mode = !m || !strcmp(m, "off") ? M_OFF : !strcmp(m, "probe") ? M_PROBE
       : !strcmp(m, "fixed") ? M_FIXED : !strcmp(m, "jitter") ? M_JITTER
       : !strcmp(m, "stall") ? M_STALL : !strcmp(m, "stretch") ? M_STRETCH : M_OFF;
  if (mode == M_OFF) return;
  topic_name = getenv("FI3_TOPIC") ? getenv("FI3_TOPIC") : "rt/vehicle/status/velocity_status";
  delay_ns = (int64_t)(envf("FI3_DELAY_MS", 0) * 1e6);
  jitter_ns = (int64_t)(envf("FI3_JITTER_MS", 0) * 1e6);
  stall_ns = (int64_t)(envf("FI3_STALL_MS", 0) * 1e6);
  double hz = envf("FI3_RATE_HZ", 0);
  period_ns = hz > 0 ? (int64_t)(1e9 / hz) : 0;
  start_ns = (int64_t)(envf("FI3_START_S", 0) * 1e9);
  dur_ns = (int64_t)(envf("FI3_DURATION_S", 0) * 1e9);
  stall_latest = getenv("FI3_STALL_POLICY") && !strcmp(getenv("FI3_STALL_POLICY"), "latest");
  qmax = (size_t)envf("FI3_QUEUE_MAX", 1024);
  logf = fopen(getenv("FI3_LOG") ? getenv("FI3_LOG") : "/tmp/fi3_shim.log", "a");
  char armed[256];
  snprintf(armed, sizeof armed, "[FI3] ARMED topic=%s mode=%s delay_ms=%g jitter_ms=%g stall_ms=%g "
           "policy=%s rate_hz=%g start_s=%g duration_s=%g", topic_name, m, delay_ns / 1e6,
           jitter_ns / 1e6, stall_ns / 1e6, stall_latest ? "latest" : "flush", hz,
           start_ns / 1e9, dur_ns / 1e9);
  fprintf(stderr, "%s\n", armed);
  logln("# %s", armed);
  logln("# topic seq t_in_wall_ns t_out_wall_ns delay_ms action");
  if (mode == M_PROBE) return;
  q = calloc(qmax, sizeof *q);
  pthread_condattr_t ca; pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
  pthread_cond_init(&cv, &ca);
  pthread_t th; pthread_create(&th, NULL, sender, NULL); pthread_detach(th);
}

dds_entity_t dds_create_topic_sertype(dds_entity_t pp, const char *name, struct ddsi_sertype **st,
                                      const dds_qos_t *qos, const dds_listener_t *listener,
                                      const struct ddsi_plist *sedp_plist) {
  pthread_once(&once, init);
  resolve();
  dds_entity_t tp = real_create_topic(pp, name, st, qos, listener, sedp_plist);
  if (mode == M_OFF || tp < 0) return tp;
  pthread_mutex_lock(&mu);
  if (mode == M_PROBE) logln("TOPIC %s", name);
  /* read *st after the call: Cyclone may swap in an already-registered sertype */
  if (!strcmp(name, topic_name) && ntargets < MAX_TARGETS)
    targets[ntargets].tp = tp, targets[ntargets++].st = *st;
  pthread_mutex_unlock(&mu);
  return tp;
}

static const struct ddsi_sertype *target_sertype(dds_entity_t wr) {
  if (ntargets == 0) return NULL;
  dds_entity_t tp = real_get_topic(wr);
  for (int i = 0; i < ntargets; i++)
    if (targets[i].tp == tp) return targets[i].st;
  return NULL;
}

dds_return_t dds_write(dds_entity_t wr, const void *data) {
  pthread_once(&once, init);
  resolve();
  if (mode == M_OFF) return real_write(wr, data);
  pthread_mutex_lock(&mu);
  const struct ddsi_sertype *st = target_sertype(wr);
  if (!st || mode == M_PROBE) {
    if (st && seq++ == 0) logln("PROBE_WRITE %s", topic_name);
    pthread_mutex_unlock(&mu);
    return real_write(wr, data);
  }
  struct ddsi_serdata *d = st->serdata_ops->from_sample(st, SDK_DATA, data);
  if (!d) { pthread_mutex_unlock(&mu); return real_write(wr, data); }

  int64_t t = now_ns(CLOCK_MONOTONIC);
  if (t_first < 0) t_first = t;
  int64_t rel_t = t - t_first;
  int active = rel_t >= start_ns && (dur_ns == 0 || rel_t < start_ns + dur_ns);
  int64_t rel = t, replace_tail = 0;
  switch (active ? mode : M_OFF) {
    case M_FIXED: rel = t + delay_ns; break;
    case M_JITTER:
      rel = t + delay_ns + (jitter_ns ? (int64_t)((rand_r(&rnd) / (double)RAND_MAX * 2 - 1) * jitter_ns) : 0);
      break;
    case M_STALL:   /* window [start, start+STALL); duration is ignored */
      if (rel_t < start_ns + stall_ns) { rel = t_first + start_ns + stall_ns; replace_tail = stall_latest; }
      break;
    case M_STRETCH: /* at most one release per period, newest wins */
      if (period_ns) { rel = last_rel + period_ns > t ? last_rel + period_ns : t; replace_tail = 1; }
      break;
    default: break;
  }
  if (rel < last_rel) rel = last_rel;          /* FIFO: never overtake */

  struct item it = { wr, d, seq++, t, now_ns(CLOCK_REALTIME), rel };
  if (replace_tail && qlen > 0) {
    struct item *tail = &q[(qhead + qlen - 1) % qmax];
    log_item(tail, 0, "drop");
    free_serdata(tail->d);
    it.t_rel = tail->t_rel;
    *tail = it;
  } else if (qlen == qmax) {
    log_item(&it, 0, "drop_full");
    free_serdata(d);
  } else {
    q[(qhead + qlen++) % qmax] = it;
    last_rel = rel;
  }
  pthread_cond_signal(&cv);
  pthread_mutex_unlock(&mu);
  return DDS_RETCODE_OK;
}
