/* fi1_stuck_sensor — FI1 (Data Age Violation) injector.
 *
 * A Path A writer (real Cyclone participant, so it is discovered and its samples
 * get a fresh, monotonic per-writer sequence number automatically — the reason a
 * *verbatim* replay is useless here: Cyclone's reorder admin drops seq < next_seq
 * as NN_REORDER_TOO_OLD before delivery, study/task-3-report.md:37-64). FI1
 * therefore re-emits an OLD payload through a live writer, exactly the spec's
 * "replay old data with new timestamps".
 *
 * Publishes VelocityReport on rt/vehicle/status/velocity_status with the
 * recon-confirmed writer QoS (RELIABLE + VOLATILE + KEEP_LAST(1),
 * experiments/recon/report.md:45), parameterized on three axes:
 *
 *   --value-mode stuck|replay-window   frozen value, or a looping window of old values
 *   --stamp-mode fresh|old             header.stamp = now (defeats freshness-by-stamp),
 *                                       or back-dated by --backdate-ms (age > expiry)
 *   --rate-mult N (1|2|10)             emit at N x 30 Hz (jitter / deadline stress)
 *
 * The SEU keys freshness on the message's own header.stamp (not the honest DDS
 * source_timestamp), study/task-1-report.md:696-700 — so this writer controls
 * apparent age purely by what it writes into header.stamp. */
#include "dds/dds.h"
#include "VelocityReport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop = 0;
static void on_sig(int s){ (void)s; stop = 1; }
static uint64_t now_ns(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return (uint64_t)t.tv_sec*1000000000ull + t.tv_nsec; }

static void print_guid(const char *label, dds_entity_t e){
  dds_guid_t g; if (dds_get_guid(e,&g)==DDS_RETCODE_OK){
    printf("%s ", label);
    for(int i=0;i<16;i++){ printf("%02x", g.v[i]); if(i==3||i==7||i==11) printf(":"); }
    printf("\n"); fflush(stdout);
  }
}

int main(int argc, char **argv){
  const char *value_mode = "stuck";      /* stuck | replay-window */
  const char *stamp_mode = "fresh";      /* fresh | old            */
  int    rate_mult   = 1;                /* 1 | 2 | 10             */
  double stuck_value = 5.0;              /* frozen longitudinal_velocity (m/s) */
  uint64_t backdate_ns = 2000000000ull;  /* --stamp-mode old: 2 s back-dated (>> expiry) */
  double duration_s  = 0.0;              /* 0 = until signal */

  for(int i=1;i<argc;i++){
    if(!strcmp(argv[i],"--value-mode") && i+1<argc)      value_mode = argv[++i];
    else if(!strcmp(argv[i],"--stamp-mode") && i+1<argc) stamp_mode = argv[++i];
    else if(!strcmp(argv[i],"--rate-mult") && i+1<argc)  rate_mult  = atoi(argv[++i]);
    else if(!strcmp(argv[i],"--stuck-value") && i+1<argc) stuck_value = atof(argv[++i]);
    else if(!strcmp(argv[i],"--backdate-ms") && i+1<argc) backdate_ns = (uint64_t)atoll(argv[++i])*1000000ull;
    else if(!strcmp(argv[i],"--duration") && i+1<argc)    duration_s = atof(argv[++i]);
    else { fprintf(stderr,"usage: %s [--value-mode stuck|replay-window] "
        "[--stamp-mode fresh|old] [--rate-mult 1|2|10] [--stuck-value V] "
        "[--backdate-ms M] [--duration S]\n", argv[0]); return 2; }
  }
  if(rate_mult < 1) rate_mult = 1;
  int backdate = !strcmp(stamp_mode,"old");
  int windowed = !strcmp(value_mode,"replay-window");
  /* a small window of "old" values to loop when --value-mode replay-window */
  const float window[] = { 5.0f, 5.5f, 6.0f, 5.5f };
  const int   window_n = (int)(sizeof window / sizeof window[0]);

  signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
  dds_entity_t dp = dds_create_participant(DDS_DOMAIN_DEFAULT, NULL, NULL);
  if (dp<0){ fprintf(stderr,"participant: %s\n", dds_strretcode(-dp)); return 1; }

  dds_qos_t *q = dds_create_qos();
  dds_qset_reliability(q, DDS_RELIABILITY_RELIABLE, DDS_SECS(1));
  dds_qset_durability (q, DDS_DURABILITY_VOLATILE);
  dds_qset_history    (q, DDS_HISTORY_KEEP_LAST, 1);

  dds_entity_t tp = dds_create_topic(dp,
      &autoware_vehicle_msgs_msg_dds__VelocityReport__desc,
      "rt/vehicle/status/velocity_status", NULL, NULL);
  if (tp<0){ fprintf(stderr,"topic: %s\n", dds_strretcode(-tp)); return 1; }
  dds_entity_t wr = dds_create_writer(dp, tp, q, NULL);
  if (wr<0){ fprintf(stderr,"writer: %s\n", dds_strretcode(-wr)); return 1; }
  dds_delete_qos(q);

  print_guid("WRITER_GUID", wr);   /* the FOREIGN GUID the consumer will log */
  printf("fi1_stuck_sensor up: value-mode=%s stamp-mode=%s rate-mult=%dx "
    "(%.1f Hz) stuck=%.3f backdate_ms=%llu\n",
    value_mode, stamp_mode, rate_mult, 30.0*rate_mult, stuck_value,
    (unsigned long long)(backdate_ns/1000000ull));
  fflush(stdout);

  autoware_vehicle_msgs_msg_dds__VelocityReport_ s;
  memset(&s,0,sizeof s);
  s.header.frame_id = "base_link";

  uint64_t seq = 0;
  const uint64_t period_ns = 33333333ull / (uint64_t)rate_mult; /* 30 Hz x rate_mult */
  uint64_t next = now_ns();
  uint64_t t0 = now_ns();

  while(!stop){
    if(duration_s > 0.0 && (double)(now_ns()-t0)/1e9 >= duration_s) break;

    /* OLD payload: frozen value (stuck) or a looping window of old values. */
    s.longitudinal_velocity = windowed ? window[seq % window_n] : (float)stuck_value;

    /* NEW (or back-dated) header.stamp — this is the apparent age the SEU reads. */
    uint64_t stamp_ns = now_ns();
    if(backdate) stamp_ns = (stamp_ns > backdate_ns) ? stamp_ns - backdate_ns : 0;
    s.header.stamp.sec     = (int32_t)(stamp_ns / 1000000000ull);
    s.header.stamp.nanosec = (uint32_t)(stamp_ns % 1000000000ull);

    dds_return_t rc = dds_write(wr, &s);
    printf("TX seq=%llu t=%llu lv=%.3f stamp_ns=%llu stamp_age_ms=%.1f write_rc=%s\n",
      (unsigned long long)seq,(unsigned long long)now_ns(), s.longitudinal_velocity,
      (unsigned long long)stamp_ns, (double)(now_ns()-stamp_ns)/1e6,
      rc==DDS_RETCODE_OK?"OK":dds_strretcode(-rc));
    fflush(stdout);

    seq++;
    next += period_ns;
    uint64_t n = now_ns();
    if (next > n){ struct timespec ts={ .tv_sec=(next-n)/1000000000ull,
        .tv_nsec=(next-n)%1000000000ull }; nanosleep(&ts,NULL); }
    else next = n; /* fell behind (e.g. 10x + WHC back-pressure) — record, don't tune */
  }
  printf("fi1_stuck_sensor: stopped after %llu samples\n",(unsigned long long)seq);
  dds_delete(dp);
  return 0;
}
