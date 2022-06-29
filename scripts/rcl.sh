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

themode=              # first argument, mode 'setup' 'tree' 'select', 'mcl', or 'qc'
projectdir=           # second argument, for modes 'setup' 'tree' 'select'.
network=              # -n FNAME
tabfile=              # -t FNAME
infix='infix'         # -x infix, a secondary tag
cpu=1                 # -p NUM
RESOLUTION=           # -r, e.g. -r "100 200 400 800 1600 3200"
ANNOTATION=           # -a FNAME annotation file
CLUSTERING=           # -c FNAME clustering file
do_force=false        # -F (for mode 'tree')
INFLATION=            # -I, e.g. -I "1.3 1.35 1.4 1.45 1.5 1.55 1.6 1.65 1.7 1.8 1.9 2"
SELF=                 # -D
test_ucl=false        # -U

function usage() {
  local e=$1
  cat <<EOH
An rcl workflow requires three steps:

1) rcl.sh setup   TAG -n NETWORKFILENAME -t TABFILENAME  LIST-OF-CLUSTERING-FILES
2) rcl.sh tree    TAG [-F] [-p NCPU]
3) rcl.sh select  TAG -r "RESOLUTIONLIST"

TAG will be used as a project directory name in the current directory.
NETWORKFILENAME and TABFILENAME are usually created by mcxload.
Hard links to these files will be made in TAG, symbolic if this is not possible.
All rcl.sh commands are issued from outside and directly above directory TAG.
LIST-OF-CLUSTERING-FILES is stored in a file and retrieved when needed.
-F forces a run if a previous output exists.
For RESOLUTIONLIST a doubling is suggested, e.g. -r "50 100 200 400 800 1600 3200"
You may want to re-run with a modified list if the largest cluster size is either
too small or too large for your liking.
The history of your commands will be tracked in TAG/rcl.cline.
If 'dot' is available, a plot of results is left in TAG/rcl.hi.RESOLUTION.pdf
A table of all clusters of size above the smallest resolution is left in TAG/rcl.hi.RESOLUTION.txt

To make mcl clusterings to give to rcl:
rcl.sh mcl TAG [-p NCPU] -n NETWORKFILENAME -I "INFLATIONLIST"
This may take a while for large graphs.
In step 1) you can then use
   rcl.sh setup TAG -n NETWORKFILENAME -t TABFILENAME
INFLATIONLIST:
- for single cell use e.g. -I "1.3 1.35 1.4 1.45 1.5 1.55 1.6 1.65 1.7 1.8 1.9 2"
- for protein families you will probably want somewhat larger values

Additional modes:
rcl.sh qc  TAG      create (1) heat map of clustering discrepancies and (2) granularity plot.
rcl.sh qc2 TAG      create scatter plot of cluster sizes versus induced mean eccentricity of nodes.
rcl.sh heatannot TAG  -a annotationfile -c rclheatmapfile (output from rcl select, TAG/rcl.hm*)
rcl.sh heatannotcls TAG  -a annotationfile -c clustering (in mcl matrix format)
                    These two modes create a heatmap from an annotation file, where each
                    node is scored for the same list of traits. Scores are added for each trait and
                    each cluster by adding all scores for that trait for all nodes in the cluster.
EOH
  exit $e
}

MODES="setup tree select mcl qc qc2 heatannot heatannotcls"

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
function require_file() {
  local fname=$1 response=$2
  if [[ ! -f $fname ]]; then
    echo "Expected file $fname not found; $response"
    false
  fi
}
function require_imx() {
  local fname=$1 response=$2
  require_file "$fname" "$response"
  if ! mcx query -imx $fname --dim > /dev/null; then
    echo "Input is not in mcl network format; check file $fname"
    false
  fi
}
function test_absence () {
  local fname=$1
  local action=${2:?Programmer error, need second argument}  # return or exit
  if [[ -f $fname ]]; then
    if $do_force; then
      echo "Recreating existing file $fname"
    else
      echo "File $fname exists, use -F to force renewal"
      if [[ $action == 'return' ]]; then
        return 1
      elif [[ $action == 'exit' ]]; then
        exit 1
      fi
    fi
  fi
}

require_mode "${1-}"          # themode now set
shift 1
if grep -qFw $themode <<< "setup tree select mcl qc qc2 heatannot heatannotcls"; then
  require_tag $themode "${1-}"   # projectdir now set
  shift 1
fi

pfx=
if [[ -n $projectdir ]]; then
   mkdir -p $projectdir
   pfx=$projectdir/rcl
   echo -- "$themode $projectdir $@" >> $pfx.cline
fi


while getopts :a:c:n:p:r:t:x:I:FDU opt
do
    case "$opt" in
    a) ANNOTATION=$OPTARG ;;
    c) CLUSTERING=$OPTARG ;;
    n) network=$OPTARG ;;
    p) cpu=$OPTARG ;;
    r) RESOLUTION=$OPTARG ;;
    t) tabfile=$OPTARG ;;
    x) infix=$OPTARG ;;
    I) INFLATION=$OPTARG ;;
    F) do_force=true ;;
    D) SELF="--self" ;;
    U) test_ucl=true ;;
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
  require_opt mcl -I "$INFLATION" "a set of inflation values between quotes"
  if (( n_req )); then exit 1; fi
  mkdir -p $projectdir
  echo "-- Running mcl for inflation values in ($INFLATION)"
  for I in $(tr -s ' ' '\n' <<< "$INFLATION" | sort -rn); do
    echo -n "-- inflation $I start .."
    mcl $network -I $I -t $cpu --i3 -odir $projectdir ${RCL_MCL_OPTIONS:-}
    echo " done"
  done 2> $projectdir/log.mcl
  echo $projectdir/out.*.I* | tr ' ' '\n' > $projectdir/rcl.lsocls
  exit 0


  ##
  ##  S E T U P

elif [[ $themode == 'setup' ]]; then
  require_opt setup -n "$network" "a network in mcl format"
  require_opt setup -t "$tabfile" "a tab file mapping indexes to labels"
  if (( n_req )); then exit 1; fi
  require_imx "$network" "Is $network an mcl matrix file?"

  ndim=$(grep -o "[0-9]\+$" <<< $(mcx query --dim -imx "$network"))
  ntab=$(wc -l < "$tabfile")

  if [[ $ntab != $ndim ]]; then
    echo "Dimension mismatch between network ($ndim) and tab file ($ntab)"
    false
  fi

  if ! test_absence $pfx.lsocls return; then
    true # echo "-- using existing file $pfx.lsocls"
  else
    (( $# < 2 )) && echo "Please supply a few clusterings" && false
    ls "$@" > $pfx.lsocls
    for f in $(cat $pfx.lsocls); do
      require_imx "$f" "Is clustering $f an mcl matrix file?"
    done
    echo "-- Supplied clusterings are in mcl format"
  fi

  if ! ln -f $tabfile $pfx.tab 2> /dev/null; then
    cp $tabfile $pfx.tab
  fi
  if ! ln -f $network $pfx.input 2> /dev/null; then
    ln -sf $network $pfx.input
  fi
  wc -l < $pfx.tab > $pfx.nitems
  echo "Project directory $projectdir is ready ($pfx.input)"


  ##
  ##  T R E E

elif [[ $themode == 'tree' ]]; then
  require_imx "$pfx.input" "did you run rcl.sh setup $projectdir?"
  require_file "$pfx.lsocls" "cluster file $pfx.lsocls is missing, weirdly"

  rclfile=$pfx.rcl
  test_absence  "$rclfile" exit

  mapfile -t cls < $pfx.lsocls
  echo "-- Computing RCL graph on ${cls[@]}"

  if $test_ucl; then
    ucl-simple.sh "$pfx.input" "${cls[@]}"
    mv -f out.ucl $rclfile
    echo "Ran UCL succesfully, output $rclfile was made accordingly"
  elif (( cpu == 1 )); then
    clm vol --progress $SELF -imx $pfx.input -write-rcl $rclfile -o $pfx.vol "${cls[@]}"
  else
    maxp=$((cpu-1))
    list=$(eval "echo {0..$maxp}")
    echo "-- All $cpu processes are chasing .,=+<>()-"
    for id in $list; do
      clm vol --progress $SELF -imx $pfx.input -gi $id/$cpu -write-rcl $pfx.R$id -o pfx.V$id "${cls[@]}" &
    done
    wait
    clxdo mxsum $(eval echo "$pfx.R{0..$maxp}") > $rclfile
    echo "-- Components summed in $rclfile"
  fi
  echo "-- Computing single linkage join order for network $rclfile"
  clm close --sl -sl-rcl-cutoff ${RCL_CUTOFF-0} -imx $rclfile -tab $pfx.tab -o $pfx.join-order -write-sl-list $pfx.node-values
  echo "RCL network and linkage both ready, you can run rcl.sh select $projectdir"


  ##
  ##  R E S

elif [[ $themode == 'select' ]]; then
  minres=-
  require_opt select -r "$RESOLUTION" "a list of resolution values between quotes"
  (( n_req )) && false
  require_imx "$pfx.rcl" "did you run rcl.sh tree $projectdir?"
  echo "-- computing clusterings with resolution parameters $RESOLUTION"
  export MCLXIOVERBOSITY=2
  # export RCL_RES_PLOT_LIMIT=${RCL_RES_PLOT_LIMIT-500}

  rcl-select.pl $pfx $RESOLUTION < $pfx.join-order
  # rcl-select.22-178.pl $pfx $RESOLUTION < $pfx.join-order

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
    cut -f 4 $rfile | mcxload -235-ai - -o $prefix.cls
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
    for minres in ${rlist[@]}; do
      resdotfile=$pfx.hi.$minres.dot
      respdffile=$pfx.hi.$minres.pdf
      restxtfile=$pfx.hi.$minres.txt
      rcl-dot-resmap.pl ${RCL_DOT_RESMAP_OPTIONS-} --minres=$minres --label=size < $resmapfile > $resdotfile
      if ! dot -Tpdf -Gsize=10,10\! < $resdotfile > $respdffile; then
        echo "-- dot did not run, pdf not produced"
      else
        echo "-- map of output produced in $respdffile"
      fi
    done
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


  ##
  ##  Q C

elif [[ $themode == 'qc' ]]; then

       #       ____  ___)              ______          ______                                 #
      #       (, /   /                (, /    )       (, /    )                              #
     #          /---/   _  __   _       /---(   _       /    / __  _   _   _____   _        #
    #        ) /   (___(/_/ (__(/_   ) / ____)_(/_    _/___ /_/ (_(_(_(_/_(_) / (_/_)_     #
   #        (_/                     (_/ (           (_/___ /         .-/                  #
  #                                                                 (_/                  #
   # Some things still hardcoded, e.g. cluster size range.
   # This looks absolutely awful, with perl madness and inline R scripts.
   # Remember that things like daisies and clover exist.
   # Additionally It Should Work

  require_file "$pfx.lsocls" "(created in step 'tree')"
  require_file "$pfx.nitems" "(created in step 'setup')"

  export RCLPLOT_PARAM_SCALE=${RCLPLOT_PARAM_SCALE:-2}
  mapfile -t cls < $pfx.lsocls

# Heatmap:
  out_heat_txt=$pfx.qc-heat.txt
  out_heat_pdf=${out_heat_txt%.txt}.pdf
  ( echo -e "d\tP1\tP2"; clm dist "${cls[@]}" | rcldo.pl distwrangle $(cat $pfx.nitems) ) > $out_heat_txt # \

  R --slave --quiet --silent --vanilla <<EOR
library(ggplot2, warn.conflicts=FALSE)
library(viridis, warn.conflicts=FALSE)

mytheme = theme(plot.title = element_text(hjust = 0.5), plot.margin=grid::unit(c(5,5,5,5), "mm"),
   axis.text.x=element_text(size=rel(1.0), angle=0), axis.text.y=element_text(size=rel(1.0), angle=0), 
   legend.position="bottom", legend.text=element_text(size=rel(0.6)), legend.title=element_text(size=rel(0.8)),
   text=element_text(family="serif"))
  
h <- read.table("$out_heat_txt",header=T, colClasses=c("double", "character", "character"))
h\$d <- 100 * h\$d

p1 <- ggplot(h, aes(x=P1, y=P2, fill=d)) +  
     geom_tile() + mytheme + ggtitle("Cluster discrepancies") +
     guides(shape = guide_legend(override.aes = list(size = 0.3))) +
     labs(x="Granularity parameter", y="Granularity parameter") +
     geom_text(aes(label=round(d)), color="white", size=4) + scale_fill_viridis(option = "A",
       name = "Distance to GCS as percentage of nodes", direction = -1, limits=c(0,100),
       guide = guide_colourbar(direction = "horizontal",
       draw.ulim = F,
       title.hjust = 0.5,
       barheight = unit(3, "mm"),
       label.hjust = 0.5, title.position = "top"))
ggsave("$out_heat_pdf", width=${RCLPLOT_X:-6}, height=${RCLPLOT_Y:-5}); 
EOR
  echo "-- $out_heat_pdf created"

# Granularity:
  out_gra_txt="$pfx.qc-gra.txt"
  out_gra_pdf="${out_gra_txt%.txt}.pdf"
  for fname in "${cls[@]}"; do
    clxdo gra $fname | tr -s ' ' '\n' | tail -n +2 | rcldo.pl cumgra $fname $(cat $pfx.nitems)
  done > "$out_gra_txt"
  R --slave --quiet --silent --vanilla <<EOR
library(ggplot2, warn.conflicts=FALSE)

mytheme = theme(plot.title = element_text(hjust = 0.5),
  plot.margin=grid::unit(c(4,4,4,4), "mm"), legend.spacing.y=unit(0, 'mm'), legend.key.size = unit(5, "mm"),
               text=element_text(family="serif"))

a <- read.table("$out_gra_txt", colClasses=c("factor", "double", "double"))
xLabels <- c(1,10,100,1000,10000)
  ggplot(a) + geom_line(aes(x = V2, y = V3, group=V1, colour=V1)) +
  mytheme + scale_color_viridis_d() +
  geom_point(aes(x = V2, y = V3, group=V1, colour=V1)) +
  labs(col="${RCLPLOT_GRA_COLOUR:-Granularity parameter}", x="Cluster size x", y=expression("Fraction of nodes in clusters of size "<="x")) +
  scale_x_continuous(breaks = c(0,10,20,30,40),labels= xLabels) +
  ggtitle("${RCLPLOT_GRA_TITLE:-Granularity signatures across inflation}")
ggsave("$out_gra_pdf", width=${RCLPLOT_X:-6}, height=${RCLPLOT_Y:-4})
EOR
  echo "-- $out_gra_pdf created"


elif [[ $themode == 'qc2' ]]; then

  require_file "$pfx.lsocls" "(created in step 'tree')"
  export MCLXIOVERBOSITY=2
  mapfile -t cls < $pfx.lsocls

  # if $do_force || [[ ! -f $pfx.qc2all.txt ]]; then
  if ! test_absence  $pfx.qc2all.txt return; then
    echo "-- reusing $pfx.qc2all.txt"
  else

    for cls in ${cls[@]}; do

      export tag=$(rcldo.pl clstag $cls)
      ecc_file=$pfx.ecc.$tag.txt
      cls_dump=$pfx.clsdump.$tag

      echo "-- computing cluster-wise eccentricity for $cls [$tag]"
      mcx alter -icl $cls -imx $pfx.input --block | mcx diameter -imx - -t $cpu --progress | tail -n +2 > $ecc_file

      mcxdump -imx $cls --transpose --no-values > $cls_dump

      if ! diff -q <(cut -f 1 $ecc_file) <(cut -f 1 $cls_dump); then
        echo "Difference in domains!"
        false
      fi

      paste $ecc_file  <(cut -f 2 $cls_dump) \
        | sort -nk 3 \
        | datamash --group 3 mean 2 count 3 \
        | perl -ne 'chomp; print "$_\t$ENV{tag}\n"' \
        > $pfx.qc2.$tag.txt

    done
    cat $pfx.qc2.*.txt | tac > $pfx.qc2all.txt
  fi

  out_qc2_pdf=$pfx.qc2all.pdf

  R --slave --quiet --silent --vanilla <<EOR
library(ggplot2, warn.conflicts=FALSE)
library(viridis, warn.conflicts=FALSE)
d <- read.table("$pfx.qc2all.txt")
d <- d[d\$V3 > 1,]          # remove singletons.
d\$V4 <- as.factor(d\$V4)
mytheme = theme(plot.title = element_text(hjust = 0.5),
  plot.margin=grid::unit(c(4,4,4,4), "mm"), legend.spacing.y=unit(0, 'mm'), legend.key.size = unit(5, "mm"),
               text=element_text(family="serif"))
ggplot() + mytheme +
geom_point(data=d, aes(x=V2, y=log10(V3), colour=V4)) +
expand_limits(x=c(0,${RCL_ECC_X:-10}), y=c(0,${RCL_ECC_Y:-5})) +
labs(colour = "Cls", x="Average eccentricity", y="Cluster size (log10)") +
scale_color_viridis(discrete=TRUE, labels=as.numeric(levels(d\$V4))/10**${RCLPLOT_PARAM_SCALE:-0}) +
ggtitle("${RCLPLOT_ECC_TITLE:-Cluster size / eccentricity}")
ggsave("$out_qc2_pdf", width=${RCLPLOT_X:-5}, height=${RCLPLOT_Y:-5})
EOR
  echo "-- file $out_qc2_pdf created"


elif [[ $themode == 'heatannot' || $themode == 'heatannotcls' ]]; then

require_opt $themode -c "$CLUSTERING" "an rcl.hm.*.txt file or clustering in mcl matrix format"
require_opt $themode -a "$ANNOTATION" "an annotation table with header line, row names as in tab file"

require_file "$CLUSTERING" "(file $projectdir/rcl.hm.*.txt for heatannot or clustering in mcl matrix format for heatannotcls)"
require_file "$ANNOTATION" "an annotation table with header line, row names as in tab file"

mybase=$projectdir/hm${infix:+.$infix}

if [[ $themode == heatannotcls ]]; then
  clsinput=$CLUSTERING
  CLUSTERING=$mybase.thecls.txt
  mcxdump -imx $clsinput --dump-rlines --no-values > $CLUSTERING
fi

how=created
if test_absence $mybase.fq.txt return; then
  # rcldo.pl $themode $ANNOTATION $CLUSTERING $projectdir/rcl.tab > $mybase.txt
  rcldo.pl $themode $ANNOTATION $CLUSTERING $projectdir/rcl.tab $mybase
else
  how=reused
fi
echo "-- file $mybase.fq.txt $how"

  R --slave --quiet --silent --vanilla <<EOR
suppressPackageStartupMessages(library(circlize, warn.conflicts=FALSE))
suppressPackageStartupMessages(library(ComplexHeatmap, warn.conflicts=FALSE))
suppressPackageStartupMessages(library(DECIPHER, warn.conflicts=FALSE))           # For newick read
col_mp    = colorRamp2(c(0, 1, 2, 3, 4, 5), c("darkred", "orange", "lightgoldenrod", "white", "lightblue", "darkblue"))
col_logit = colorRamp2(c(-2, -1, 0, 1, 2, 4, 6)-4, c("darkblue", "lightblue", "white", "lightgoldenrod", "orange", "red", "darkred"))
col_freq  = colorRamp2(c(-5,-3,0,1,2,3,5), c("darkblue", "lightblue", "white", "lightgoldenrod", "orange", "red", "darkred"))

g  <- read.table("$mybase.sum.txt", header=T, sep="\t")
type_bg = as.numeric(g[1,4:ncol(g)])
g2 <- as.matrix(g[2:nrow(g),4:ncol(g)])
termsz <- as.numeric(g[1,4:ncol(g)])
clssz  <- g[2:nrow(g),3]
totalclssz <- g\$Size[1]
g3 <- apply(g2, 2, function(x) { x / (clssz/totalclssz)})
g4 <- apply(g3, 1, function(y) { log(y / termsz) })
#g3 <- apply(g2, 2, function(x) { x / clssz })
#g4 <- apply(g3,1, function(y) { -log(totalclssz * y / termsz) })

pdf("$mybase.fq.pdf", width = ${RCLPLOT_X:-8}, height = ${RCLPLOT_Y:-8})

myclr <- col_freq

r  <- FALSE             # Either FALSE or a dendrogram ...

if ("$themode" == 'heatannot') {
  r  <- ReadDendrogram("$mybase.nwk")
  if (nobs(r) != ncol(g4)) {
    print(paste("Check rcl.sh select/heatannot runs had matching parameters RCLPLOT_HEAT_LIMIT RCLPLOT_HEAT_NOREST"))
    stop(sprintf("Dendrogram has %d elements, table $mybase.sum.txt has %d elements", nobs(r), ncol(g4)))
  }
  # fixme: check dendrogram order AGAIN.
  g4 <- g4[,order(order.dendrogram(r))]
}

  ## the first value is the first residual cluster, usually much larger than the rest.
clr_size = colorRamp2(c(0, median(g\$Size[-1]), max(g\$Size[-c(1,2)])), c("white", "lightgreen", "darkgreen"))
clr_type = colorRamp2(c(0, median(type_bg), max(type_bg)), c("white", "plum1", "purple4"))
size_ha  = HeatmapAnnotation(Size = g\$Size[-1], col=list(Size=clr_size))
type_ha  = HeatmapAnnotation(Type = type_bg, col=list(Type=clr_type), which='row')
ht <- Heatmap(g4, name = "${RCLHM_NAME:-Heat}",
  column_title = "${RCLHM_XTITLE:-Clusters}", row_title = "${RCLHM_YTITLE:-Annotation}",
  cluster_rows = ${RCLHM_ROWCLUSTER:-FALSE},
  cluster_columns= r,
  top_annotation = size_ha,
  right_annotation = type_ha,
  col=myclr,
  row_names_gp = gpar(fontsize = ${RCLPLOT_YFTSIZE:-8}),
  show_column_names = FALSE,
  row_labels=lapply(rownames(g4), function(x) { substr(x, 1, ${RCLPLOT_YLABELMAX:-20}) }))

options(repr.plot.width = ${RCLPLOT_HM_X:-20}, repr.plot.height = ${RCLPLOT_HM_Y:-16}, repr.plot.res = 100)
ht = draw(ht)
invisible(dev.off())
EOR

echo "-- file $mybase.fq.pdf created"
echo "-- file $mybase.mp.pdf created"

fi


