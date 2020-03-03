#!/bin/bash
# 2020 slegroux@ccrma.stanford.edu

# Set -e here so that we catch if any executable fails immediately
set -euo pipefail
njobs=$(($(nproc)-1))
stage=10
train_set=train
gmm=tri3b
nnet3_affix=_online_cmn

echo "$0 $@"  # Print the command line for logging

. cmd.sh
. path.sh
. utils/parse_options.sh

n_speakers_test=$(cat data/${train_set}/spk2utt | wc -l)
if [ $njobs -le $n_speakers_test ]; then
  nj=$njobs
else
  nj=$n_speakers_test
fi

gmm_dir=exp/$gmm
ali_dir=data/${train_set}/${gmm}_ali
tree_dir=exp/chain${nnet3_affix}/tree_${train_set}
lang=data/lang_chain
lat_dir=data/${train_set}/${gmm}_lats
train_data_dir=data/${train_set}_hires
lores_train_data_dir=data/${train_set}
train_ivector_dir=data/${train_set}_hires/ivectors

if [ ! -f $ali_dir/ali.1.gz ]; then
  steps/align_fmllr.sh --nj 60 --cmd "$train_cmd" \
    data/${train_set} data/lang $gmm_dir $ali_dir || exit 1
fi

for f in $gmm_dir/final.mdl $train_data_dir/feats.scp $train_ivector_dir/ivector_online.scp \
    $lores_train_data_dir/feats.scp $ali_dir/ali.1.gz; do
  [ ! -f $f ] && echo "$0: expected file $f to exist" && exit 1
done

if [ $njobs -le $n_speakers_test ]; then
  nj=$njobs
else
  nj=$n_speakers_test
fi

if [ $stage -le 10 ]; then
  echo "$0: creating lang directory $lang with chain-type topology"
  # Create a version of the lang/ directory that has one state per phone in the
  # topo file. [note, it really has two states.. the first one is only repeated
  # once, the second one has zero or more repeats.]
  if [ -d $lang ]; then
    if [ $lang/L.fst -nt data/lang/L.fst ]; then
      echo "$0: $lang already exists, not overwriting it; continuing"
    else
      echo "$0: $lang already exists and seems to be older than data/lang..."
      echo " ... not sure what to do.  Exiting."
      exit 1;
    fi
  else
    cp -r data/lang $lang
    silphonelist=$(cat $lang/phones/silence.csl) || exit 1;
    nonsilphonelist=$(cat $lang/phones/nonsilence.csl) || exit 1;
    # Use our special topology... note that later on may have to tune this
    # topology.
    steps/nnet3/chain/gen_topo.py $nonsilphonelist $silphonelist >$lang/topo
  fi
fi

if [ $stage -le 11 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  steps/align_fmllr_lats.sh --nj 60 --cmd "$train_cmd" ${lores_train_data_dir} \
    data/lang $gmm_dir $lat_dir
  rm $lat_dir/fsts.*.gz # save space
fi

if [ $stage -le 12 ]; then
  # Build a tree using our new topology.  We know we have alignments for the
  # speed-perturbed data (local/nnet3/ltor_common.sh made them), so use
  # those.  The num-leaves is always somewhat less than the num-leaves from
  # the GMM baseline.
   if [ -f $tree_dir/final.mdl ]; then
     echo "$0: $tree_dir/final.mdl already exists, refusing to overwrite it."
     exit 1;
  fi
  steps/nnet3/chain/build_tree.sh \
    --frame-subsampling-factor 3 \
    --context-opts "--context-width=2 --central-position=1" \
    --cmd "$train_cmd" 3500 ${lores_train_data_dir} \
    $lang $ali_dir $tree_dir
fi