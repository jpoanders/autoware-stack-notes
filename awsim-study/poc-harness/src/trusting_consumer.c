/* trusting_consumer — Stage-1 harness stand-in for a downstream node that
 * trusts the ego speed for actuation. Subscribes with the recon-confirmed
 * reader QoS (VOLATILE, RELIABLE, KEEP_LAST). For every sample it logs the raw
 * observables the SEU's STL monitor evaluates: arrival timestamp, source writer
 * GUID, and longitudinal_velocity. A built-in freshness watchdog emits the
 * age(topic) trace: once no sample from the tracked source arrives within
 * DELTA_FRESH it prints the growing age — the exact signal Module 1 must create
 * (silent freshness loss with no clean shutdown event). */
#include "dds/dds.h"
#include "VelocityReport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>

#define MAXS 32
#define DELTA_FRESH_MS 165.0   /* ~5 x 33ms nominal inter-arrival (30 Hz) */

static volatile sig_atomic_t stop = 0;
static void on_sig(int s){ (void)s; stop = 1; }
static uint64_t now_ns(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
  return (uint64_t)t.tv_sec*1000000000ull + t.tv_nsec; }

static void guid_str(const dds_guid_t *g, char *out){
  char *p=out; for(int i=0;i<16;i++){ p+=sprintf(p,"%02x",g->v[i]);
    if(i==3||i==7||i==11) p+=sprintf(p,":"); } }

int main(void){
  signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
  dds_entity_t dp = dds_create_participant(DDS_DOMAIN_DEFAULT, NULL, NULL);
  if (dp<0){ fprintf(stderr,"participant: %s\n", dds_strretcode(-dp)); return 1; }
  { dds_guid_t g; if(dds_get_guid(dp,&g)==DDS_RETCODE_OK){
      printf("CONSUMER_PREFIX "); for(int i=0;i<12;i++) printf("%02x",g.v[i]); printf("\n"); fflush(stdout);} }

  dds_qos_t *q = dds_create_qos();
  dds_qset_reliability(q, DDS_RELIABILITY_RELIABLE, DDS_SECS(1));
  dds_qset_durability (q, DDS_DURABILITY_VOLATILE);
  dds_qset_history    (q, DDS_HISTORY_KEEP_LAST, 10);

  dds_entity_t tp = dds_create_topic(dp,
      &autoware_vehicle_msgs_msg_dds__VelocityReport__desc,
      "rt/vehicle/status/velocity_status", NULL, NULL);
  dds_entity_t rd = dds_create_reader(dp, tp, q, NULL);
  if (rd<0){ fprintf(stderr,"reader: %s\n", dds_strretcode(-rd)); return 1; }
  dds_delete_qos(q);
  printf("trusting_consumer up: VOLATILE reader; DELTA_FRESH=%.0f ms\n", DELTA_FRESH_MS);
  fflush(stdout);

  dds_entity_t ws = dds_create_waitset(dp);
  dds_entity_t rc = dds_create_readcondition(rd, DDS_ANY_STATE);
  dds_waitset_attach(ws, rc, rd);

  void *samples[MAXS] = {0};
  dds_sample_info_t infos[MAXS];

  uint64_t last_arrival = 0;     /* monotonic ns of last live sample */
  int stale_announced = 0;
  char last_guid[64] = "(none)";
  uint64_t rxcount = 0;

  while(!stop){
    dds_attach_t tr[1];
    (void)dds_waitset_wait(ws, tr, 1, DDS_MSECS(30)); /* poll ~1 nominal period */
    int n = dds_take(rd, samples, infos, MAXS, MAXS);
    uint64_t t = now_ns();
    for(int i=0;i<n;i++){
      if(!infos[i].valid_data) continue;
      autoware_vehicle_msgs_msg_dds__VelocityReport_ *m =
        (autoware_vehicle_msgs_msg_dds__VelocityReport_*)samples[i];
      char gs[64]="(unknown)";
      dds_builtintopic_endpoint_t *ep =
        dds_get_matched_publication_data(rd, infos[i].publication_handle);
      if(ep){ guid_str(&ep->key, gs); dds_builtintopic_free_endpoint(ep); }
      strncpy(last_guid, gs, sizeof last_guid-1);
      double dt_ms = last_arrival? (double)(t-last_arrival)/1e6 : 0.0;
      last_arrival = t;
      if(stale_announced){ printf("TRACE t=%llu event=RECOVER guid=%s\n",
          (unsigned long long)t, gs); stale_announced=0; }
      printf("TRACE t=%llu event=SAMPLE rx=%llu guid=%s lv=%.3f dt_ms=%.2f\n",
        (unsigned long long)t,(unsigned long long)rxcount++, gs,
        m->longitudinal_velocity, dt_ms);
      fflush(stdout);
    }
    /* freshness watchdog: age(topic) since last live sample */
    if(last_arrival){
      double age_ms = (double)(t-last_arrival)/1e6;
      if(age_ms > DELTA_FRESH_MS){
        printf("TRACE t=%llu event=STALE src=%s age_ms=%.1f (DELTA_FRESH=%.0f) %s\n",
          (unsigned long long)t, last_guid, age_ms, DELTA_FRESH_MS,
          stale_announced?"":"<-- freshness property VIOLATED");
        fflush(stdout);
        stale_announced=1;
      }
    }
  }
  printf("trusting_consumer: stopped; received %llu samples\n",(unsigned long long)rxcount);
  dds_delete(dp);
  return 0;
}
