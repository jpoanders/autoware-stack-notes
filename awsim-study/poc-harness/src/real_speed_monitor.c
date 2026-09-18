/* real_speed_monitor — Stage-1 harness stand-in for AWSIM's
 * AccelVehicleReportRos2Publisher. Publishes VelocityReport on
 * rt/vehicle/status/velocity_status at 30 Hz with the recon-confirmed
 * load-bearing QoS: RELIABLE + VOLATILE + KEEP_LAST(1). Logs each dds_write()
 * return so Module 1 can prove the source keeps succeeding after the
 * freshness-loss injection (the fault is silent at the source). */
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

int main(void){
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

  print_guid("WRITER_GUID", wr);   /* <- Module 1 target GUID (harness) */
  printf("real_speed_monitor up: 30 Hz, RELIABLE+VOLATILE+KEEP_LAST(1)\n");
  fflush(stdout);

  autoware_vehicle_msgs_msg_dds__VelocityReport_ s;
  memset(&s,0,sizeof s);
  s.header.frame_id = "base_link";
  uint64_t seq=0;
  const uint64_t period_ns = 33333333ull; /* 30 Hz */
  uint64_t next = now_ns();
  while(!stop){
    s.header.stamp.sec = (int32_t)(now_ns()/1000000000ull);
    s.longitudinal_velocity = 5.0f + 0.5f*(float)((seq/30)%3); /* ~5 m/s, moving */
    dds_return_t rc = dds_write(wr, &s);
    printf("TX seq=%llu t=%llu lv=%.3f write_rc=%s\n",
      (unsigned long long)seq,(unsigned long long)now_ns(),
      s.longitudinal_velocity, rc==DDS_RETCODE_OK?"OK":dds_strretcode(-rc));
    fflush(stdout);
    seq++;
    next += period_ns;
    uint64_t n = now_ns();
    if (next > n){ struct timespec ts={ .tv_sec=(next-n)/1000000000ull,
        .tv_nsec=(next-n)%1000000000ull }; nanosleep(&ts,NULL); }
    else next = n;
  }
  printf("real_speed_monitor: stopped after %llu samples\n",(unsigned long long)seq);
  dds_delete(dp);
  return 0;
}
