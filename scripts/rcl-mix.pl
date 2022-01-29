#!/usr/bin/perl -an

# Only reads STDIN, which should be the output of clm close in --sl mode.
# Requires a prefix for file output and a list of resolution sizes.
#
# For decreasing resolution sizes, descends each node in the tree, as long as it
# finds two independent components below the node that are both of size >= resolution.
# Once it cannot descend further for a given resolution size, it outputs the clustering,
# then proceeds with the next resolution size.

# Use e.g.
#     rcl-mix.pl pfx 50 100 200 < sl.join-order
#     mcxload -235-ai pfx50.clusters -o pfx50.cls


use strict;
use warnings;
use List::Util qw(min max);
use Scalar::Util qw(looks_like_number);


BEGIN {
  $::prefix = shift || die "Need prefix for file names";
  die "Need at least one resolution parameter\n" unless @ARGV; 
  @::resolution = sort { $b <=> $a } @ARGV;
  @ARGV = ();
  for my $r (@::resolution) {
     die "Resolution check: strange number $r\n" unless looks_like_number($r);
  }
  %::nodes = ();
  %::cid2node = ();
  $::L=1;
  %::topoftree = ();
}
next if $. == 1;
my ($i, $x, $y, $xid, $yid, $val, $xcid, $ycid, $xcsz, $ycsz, $xycsz, $nedge, $ctr, $lss, $nsg) = @F;


my ($n1, $n2) = ($xcid, $ycid);
($n1, $n2)    = ($ycid, $xcid) if $ycid < $xcid;

my $upname    = "L$::L.$n1";

if ($xcsz == 1) {
  $::cid2node{$xcid} = "L0.$xcid";
  $::nodes{"L0.$xcid"} =
  {    name => "L0.$xcid"
  ,    size =>  1
  ,   items => [ $xid ]
  ,     ann => ""
  ,     bob => ""
  ,  csizes => []
  , lss => 0
  , nsg => 0
  } ;
}
if ($ycsz == 1) {
  $::cid2node{$ycid} = "L0.$ycid";
  $::nodes{"L0.$ycid"} =
  {    name => "L0.$ycid"
  ,    size =>  1
  ,   items => [ $yid ]
  ,     ann => ""
  ,     bob => ""
  ,  csizes => []
  , lss => 0
  , nsg => 0
  } ;
}

my $node1 = $::cid2node{$n1};
my $node2 = $::cid2node{$n2};


# Keep track of the maximum size of the smaller of any pair of nodes below the current node that are
# not related by descendancy.

# Given a node N; what is the max min size of two non-nesting nodes below it.
# Its max(mms(desc1), mms(desc2), min(|desc1|, |desc2|))

   $::nodes{$upname} =
   {   name  => $upname
   ,   parent => undef
   ,   size  => $::nodes{$node1}{size} + $::nodes{$node2}{size}
   ,   items => [ @{$::nodes{$node1}{items}}, @{$::nodes{$node2}{items}} ]
   ,    ann  => $node1
   ,    bob  => $node2
   ,  csizes => [ $::nodes{$node1}{size}, $::nodes{$node2}{size}]
   , lss => max( $::nodes{$node1}{lss}, $::nodes{$node2}{lss}, min($::nodes{$node1}{size}, $::nodes{$node2}{size}))
   , nsg => $nsg
   } ;

# print STDERR "$::nodes{$upname}{lss} $lss\n";

$::cid2node{$n1} = $upname;
$::cid2node{$n2} = $upname;

delete($::topoftree{$node1});
delete($::topoftree{$node2});

$::topoftree{$upname} = 1;
$::L++;


END {
  my @inputstack = ( sort { $::nodes{$b}{size} <=> $::nodes{$a}{size} } keys %::topoftree );
  my @printstack = ();

  for my $res (@::resolution) {

    print STDERR "Processing resolution $res\n";

    while (@inputstack) {

      my $name = pop @inputstack;
      my $ann  = $::nodes{$name}{ann};
      my $bob  = $::nodes{$name}{bob};

      if ($::nodes{$name}{lss} >= $res) {
        push @inputstack, $ann;
        push @inputstack, $bob;
      }
      else {
        push @printstack, $name;
      }
    }

    my $fname = "$::prefix.res$res.info";
    open(OUT, ">$fname") || die "Cannot write to $fname";
    local $" = ' ';

    for my $name ( sort { $::nodes{$b}{size} <=> $::nodes{$a}{size} } @printstack ) {
      my $size = $::nodes{$name}{size};
      my $nsg  = sprintf("%.3f", $::nodes{$name}{nsg} / $::nodes{$name}{size});
      print OUT "$size\t$nsg\t@{$::nodes{$name}{items}}\n";
    }

    close(OUT);
    @inputstack = @printstack;
    @printstack = ();
  }
}


