#!/bin/bash
# Measure GPU rail power (ODPM CH4 S2S_VDD_G3D + CH7 S8S_VDD_G3D_L2) across a
# sustained FP32 compute run. P[W] = dE_uJ/dt_ms * 1e-3.
set -u
EV=/sys/bus/iio/devices/iio:device1/energy_value
read_rail(){ # $1=CH index ; echoes "T E"
  cat $EV | awk -v ch="CH$1(" 'NR==1{t=$1} index($0,ch){gsub(/,/,"",$NF); e=$NF} END{sub(/t=/,"",t); print t, e}'
}
# snapshot helper: returns "Tms E4 E7"
snap(){ cat $EV | awk '
  NR==1{sub(/t=/,"",$1); T=$1}
  /CH4\(/{gsub(/,/,"",$NF); E4=$NF}
  /CH7\(/{gsub(/,/,"",$NF); E7=$NF}
  END{print T, E4, E7}'; }
ENVV="$1"; SECS="${2:-12}"
B=$(snap); echo "before: $B"
OUT=$(sudo bash -c "$ENVV /home/kalm/gsustain $SECS" 2>/dev/null)
A=$(snap); echo "after:  $A"
echo "$OUT"
awk -v b="$B" -v a="$A" -v out="$OUT" 'BEGIN{
  split(b,bb," "); split(a,aa," ");
  dt=(aa[1]-bb[1]); dE=(aa[2]-bb[2])+(aa[3]-bb[3]);
  P=dE/dt*1e-3;
  # extract GFLOPS from out
  match(out,/[0-9.]+ GFLOPS/); g=substr(out,RSTART,RLENGTH); sub(/ GFLOPS/,"",g);
  printf "GPU rail power (CH4+CH7): %.3f W  over %.1f ms\n", P, dt;
  printf "FP32 efficiency: %.1f GFLOPS/W  (%.1f GFLOPS / %.3f W)\n", g/P, g, P;
}'
