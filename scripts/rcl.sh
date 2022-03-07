#!/bin/bash

# Copyright 2022 Stijn van Dongen

# This program is free software; you can redistribute it and/or modify it
# under the terms of version 3 of the GNU General Public License as published
# by the Free Software Foundation. It should be shipped with MCL in the top
# level directory as the file COPYING.

#    _ _  __|_ _. __|_ _  _|   _ _  _ _|_. _  _  _  _    |. _ |  _  _  _
#   | (/__\ | | |(_ | (/_(_|  (_(_)| | | |(_|(/_| |(_\/  ||| ||<(_|(_|(/_
#                                           |        /               |
# RCL consensus clustering
# Author: Stijn van Dongen
#
# This RCL implementation uses programs/tools that are shipped with mcl.  It
# can be run on any set of clusterings from any method or program, but the
# network and clusterings have to be supplied in mcl matrix format.
#
# See github.com/micans/mcl#rcl and this script with no arguments.

set -euo pipefail

themode=              # first argument, mode 'setup' 'tree' 'res' or 'mcl'.
projectdir=           # second argument, for modes 'setup' 'tree' 'res'.
network=              # -n FNAME
tabfile=              # -t FNAME
cpu=1                 # -p NUM
RESOLUTION=           # -r, e.g. -r "100 200 400 800 1600 3200"
do_force=false        # -F (for mode 'tree')
mcldir=               # -m DIRNAME to run a bunch of mcl analyses for use as input later
INFLATION=            # -I, e.g. -I "1.3 1.35 1.4 1.45 1.5 1.55 1.6 1.65 1.7 1.8 1.9 2"
SELF=                 # -D

function usage() {
  local e=$1
  cat <<EOH
An rcl workflow requires three steps:

1) rcl.sh setup TAG -n NETWORKFILENAME -t TABFILENAME
2) rcl.sh tree  TAG [-F] [-p NCPU] LIST-OF-CLUSTERING-FILES
3) rcl.sh res   TAG -r "RESOLUTIONLIST"

TAG will be used as a project directory name in the current directory.
NETWORKFILENAME and TABFILENAME are usually created by mcxload.
Hard links to these files will be made in TAG, symbolic if this is not possible.
All rcl.sh commands are issued from outside and directly above directory TAG.
-F forces a run if a previous output exists.
For RESOLUTIONLIST a doubling is suggested, e.g. -r "50 100 200 400 800 1600 3200"
You may want to re-run with a modified list if the largest cluster size is either
too small or too large for your liking.
The history of your commands will be tracked in TAG/rcl.cline.
If 'dot' is available, a plot of results is left in TAG/rcl.hi.RESOLUTION.pdf
A table of all clusters of size above the smallest resolution is left in TAG/rcl.hi.RESOLUTION.txt

To make mcl clusterings to give to rcl:
rcl.sh mcl [-p NCPU] -n NETWORKFILENAME -m OUTPUTDIR -I "INFLATIONLIST"
This may take a while for large graphs.
In step 2) you can then use
   rcl.sh tree TAG [-p NCPU] OUTPUTDIR/out.*
INFLATIONLIST:
- for single cell use e.g. -I "1.3 1.35 1.4 1.45 1.5 1.55 1.6 1.65 1.7 1.8 1.9 2"
- for protein families you will probably want somewhat larger values
EOH
  exit $e
}

MODES="setup tree res mcl"

function require_mode() {
  local mode=$1
  [[ -z $mode ]] && echo "Please provide a mode" && usage 0
  if ! grep -qFw -- $mode <<< "$MODES"; then
    echo "Need a mode, one of { $MODES }"; usage 1
  fi
  themode=$mode
}
function require_tag() {
  local mode=$1 tag=$2
  if [[ -z $tag ]]; then
    echo "Mode $mode requires a project directory tag"
    false
  elif [[ $tag =~ ^- ]]; then
    echo "Project directory not allowed to start with a hyphen"
    false
  fi
  projectdir=$tag
}
function require_imx() {
  local fname=$1 response=$2
  if [[ ! -f $fname ]]; then
    echo "Expected network file $fname not found; $response"
  fi
  if ! mcx query -imx $fname --dim > /dev/null; then
    echo "Input is not in mcl network format; check file $fname"
    false
  fi
}
function test_exist() {
  local fname=$1
  if [[ -f $fname ]]; then
    if ! $do_force; then
      echo "File $fname exists, use -F to force running $themode"
      exit 0
    fi
  fi
}

require_mode "${1-}"          # themode now set
shift 1
if grep -qFw $themode <<< "setup tree res"; then
  require_tag $themode "${1-}"   # projectdir now set
  shift 1
fi

pfx=
if [[ -n $projectdir ]]; then
   mkdir -p $projectdir
   pfx=$projectdir/rcl
   echo -- "$themode $projectdir $@" >> $pfx.cline
fi


while getopts :n:m:p:r:t:I:FD opt
do
    case "$opt" in
    n) network=$OPTARG ;;
    m) mcldir=$OPTARG ;;
    p) cpu=$OPTARG ;;
    r) RESOLUTION=$OPTARG ;;
    t) tabfile=$OPTARG ;;
    I) INFLATION=$OPTARG ;;
    F) do_force=true ;;
    D) SELF="--self" ;;
    :) echo "Flag $OPTARG needs argument" exit 1 ;;
    ?) echo "Flag $OPTARG unknown" exit 1 ;;
   esac
done

shift $((OPTIND-1))

function require_opt() {
  n_req=0
  local mode=$1 option=$2 value=$3 description=$4
  if [[ -z $value ]]; then
    echo "Mode $mode requires $description for option $option"
    (( ++n_req ))
  fi
}


  ##
  ##  M C L

if [[ $themode == 'mcl' ]]; then
  require_opt mcl -n "$network" "a network in mcl format"
  require_opt mcl -m "$mcldir" "a directory output name"
  require_opt mcl -I "$INFLATION" "a set of inflation values between quotes"
  if (( n_req )); then exit 1; fi
  mkdir -p $mcldir
  echo "-- Running mcl for inflation values in ($INFLATION)"
  for I in $(tr -s ' ' '\n' <<< "$INFLATION" | sort -rn); do
    echo -n "-- inflation $I start .."
    mcl $network -I $I -t $cpu --i3 -odir $mcldir
    echo " done"
  done 2> $mcldir/log.mcl
  exit 0


  ##
  ##  S E T U P

elif [[ $themode == 'setup' ]]; then
  require_opt setup -n "$network" "a network in mcl format"
  require_opt setup -t "$tabfile" "a tab file mapping indexes to labels"
  if (( n_req )); then exit 1; fi
  if ! ln -f $tabfile $pfx.tab 2> /dev/null; then
    cp $tabfile $pfx.tab
  fi
  if ! ln -f $network $pfx.input 2> /dev/null; then
    ln -sf $network $pfx.input
  fi
  echo "Project directory $projectdir is ready" 


  ##
  ##  T R E E

elif [[ $themode == 'tree' ]]; then
  require_imx "$pfx.input" "did you run rcl.sh setup $projectdir?"
  rclfile=$pfx.rcl
  test_exist "$rclfile"
  (( $# < 2 )) && echo "Please supply a few clusterings" && false
  echo "-- Computing RCL graph on $@"
  if (( cpu == 1 )); then
    clm vol --progress $SELF -imx $pfx.input -write-rcl $rclfile -o $pfx.vol "$@"
  else
    maxp=$((cpu-1))
    list=$(eval "echo {0..$maxp}")
    echo "-- All $cpu processes are chasing .,=+<>()-"
    for id in $list; do
      clm vol --progress $SELF -imx $pfx.input -gi $id/$cpu -write-rcl $pfx.R$id -o pfx.V$id "$@" &
    done
    wait
    clxdo mxsum $(eval echo "$pfx.R{0..$maxp}") > $rclfile
    echo "-- Components summed in $rclfile"
  fi
  echo "-- Computing single linkage join order for network $rclfile"
  clm close --sl -sl-rcl-cutoff ${RCL_CUTOFF-0} -imx $rclfile -tab $pfx.tab -o $pfx.join-order -write-sl-list $pfx.node-values
  echo "RCL network and linkage both ready, you can run rcl.sh res $projectdir"


  ##
  ##  R E S

elif [[ $themode == 'res' ]]; then
  minres=-
  require_opt res -r "$RESOLUTION" "a list of resolution values between quotes"
  (( n_req )) && false
  require_imx "$pfx.rcl" "did you run rcl.sh tree $projectdir?"
  echo "-- computing clusterings with resolution parameters $RESOLUTION"
  export MCLXIOVERBOSITY=2
  # export RCL_RES_PLOT_LIMIT=${RCL_RES_PLOT_LIMIT-500}

  rcl-res.pl $pfx $RESOLUTION < $pfx.join-order

  echo "-- saving resolution cluster files and"
  echo "-- displaying size of the 20 largest clusters"
  echo "-- in parentheses N identical clusters with previous level among 30 largest clusters"
                                      # To help space the granularity output.
  export CLXDO_WIDTH=$((${#pfx}+14))  # .res .cls length 8, leave 6 for resolution

  res_prev=""
  file_prev=""

  for r in $RESOLUTION; do
    rfile=$pfx.res$r.info
    if [[ ! -f $rfile ]]; then
      echo "Expected file $rfile not found"
      false
    fi
    prefix="$pfx.res$r"
    cut -f 5 $rfile | mcxload -235-ai - -o $prefix.cls
    mcxdump -icl $prefix.cls -tabr $pfx.tab -o $prefix.labels
    mcxdump -imx $prefix.cls -tabr $pfx.tab --no-values --transpose -o $prefix.txt
    nshared="--"
    if [[ -n $res_prev ]]; then
      nshared=$(grep -Fcwf <(head -n 30 $rfile | cut -f 1) <(head -n 30 $file_prev | cut -f  1) || true)
    fi
    export CLXDO_GRABIG_TAG="($(printf "%2s" $nshared)) "
    clxdo grabig 20 $prefix.cls
    res_prev=$r
    file_prev=$rfile
  done
  commalist=$(tr -s $'\t ' ',' <<< $RESOLUTION)
  hyphenlist=$(tr -s $'\t ' '-' <<< $RESOLUTION)
  resmapfile=$pfx.hi.$hyphenlist.resdot

  if [[ -f $resmapfile ]]; then
    rlist=($RESOLUTION)
    minres=${rlist[0]}
    resdotfile=${resmapfile%.resdot}.dot
    respdffile=${resmapfile%.resdot}.pdf
    restxtfile=${resmapfile%.resdot}.txt
    rcl-dot-resmap.pl ${RCL_DOT_RESMAP_OPTIONS-} --minres=$minres --label=size < $resmapfile > $resdotfile
    if ! dot -Tpdf -Gsize=10,10\! < $resdotfile > $respdffile; then
      echo "-- dot did not run, pdf not produced"
    else
      echo "-- map of output produced in $respdffile"
    fi
  else
    echo "-- Expected file $resmapfile not present"
  fi

cat <<EOM

The following outputs were made.
One cluster-per line files with labels:
   $(eval echo $pfx.res{$commalist}.labels)
LABEL<TAB>CLUSID files:
   $(eval echo $pfx.res{$commalist}.txt)
mcl-edge matrix/cluster files (suitable input e.g. for 'clm dist' and others):
   $(eval echo $pfx.res{$commalist}.cls)
A table with all clusters at different levels up to size $minres, including their nesting structure:
   $restxtfile
EOM

fi


