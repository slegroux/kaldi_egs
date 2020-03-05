#!/bin/bash
# 2020 slegroux@ccrma.stanford.edu

# Set -e here so that we catch if any executable fails immediately
set -euo pipefail


gmm=tri3b
online_cmvn_iextractor=true
nnet3_affix=_online_cmn
train_set=train
stage=0

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh


if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

# speed perturb
./local/make_sp.sh --gmm $gmm ${train_set} #includes computation of alignment of sp data

# volume perturb
./local/make_vp.sh ${train_set}_sp

# hires
./local/make_mfcc_hires.sh ${train_set}_sp_vp

./local/train_ivector.sh --gmm $gmm ${train_set}
