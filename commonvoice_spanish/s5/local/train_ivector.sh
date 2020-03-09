#!/bin/bash

set -euo pipefail

# This script is called from local/nnet3/run_tdnn.sh and
# local/chain/run_tdnn.sh (and may eventually be called by more
# scripts).  It contains the common feature preparation and
# iVector-related parts of the script.  See those scripts for examples
# of usage.

stage=4

gmm=tri3b
online_cmvn_iextractor=false

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

train_set=$1
nnet3_affix=_${train_set}_sp_vp
gmm_dir=exp/${gmm}
ali_dir=data/${train_set}_sp/${gmm}_ali

for f in data/${train_set}/feats.scp ${gmm_dir}/final.mdl; do
  if [ ! -f $f ]; then
    echo "$0: expected file $f to exist"
    exit 1
  fi
done


if [ $stage -le 4 ]; then
  echo "$0: computing a subset of data to train the diagonal UBM."
  # We'll use about a quarter of the data.
  mkdir -p exp/nnet3${nnet3_affix}/diag_ubm
  temp_data_root=exp/nnet3${nnet3_affix}/diag_ubm

  num_utts_total=$(wc -l <data/${train_set}_sp_vp_hires/utt2spk)
  num_utts=$[$num_utts_total/4]
  utils/data/subset_data_dir.sh data/${train_set}_sp_vp_hires \
     $num_utts ${temp_data_root}/${train_set}_sp_vp_hires_subset

  njobs=$(($(nproc)-1))
  n_speakers_test=$(cat ${temp_data_root}/${train_set}_sp_vp_hires_subset/spk2utt| wc -l)
  if [ $njobs -le $n_speakers_test ]; then
    nj=$njobs
  else
    nj=$n_speakers_test
  fi

  echo "$0: computing a PCA transform from the hires data."
  steps/online/nnet2/get_pca_transform.sh --cmd "$train_cmd" \
      --splice-opts "--left-context=3 --right-context=3" \
      --max-utts 10000 --subsample 2 \
       ${temp_data_root}/${train_set}_sp_vp_hires_subset \
       exp/nnet3${nnet3_affix}/pca_transform

  echo "$0: training the diagonal UBM."
  # Use 512 Gaussians in the UBM.
  steps/online/nnet2/train_diag_ubm.sh --cmd "$train_cmd" --nj $nj \
    --num-frames 700000 \
    --num-threads 8 \
    ${temp_data_root}/${train_set}_sp_vp_hires_subset 512 \
    exp/nnet3${nnet3_affix}/pca_transform exp/nnet3${nnet3_affix}/diag_ubm
fi

if [ $stage -le 5 ]; then
  # Train the iVector extractor.  Use all of the speed-perturbed data since iVector extractors
  # can be sensitive to the amount of data.  The script defaults to an iVector dimension of
  # 100.
  echo "$0: training the iVector extractor"
  steps/online/nnet2/train_ivector_extractor.sh --cmd "$train_cmd" --nj 5 \
    --num-threads 4 --num-processes 2 \
    --online-cmvn-iextractor $online_cmvn_iextractor \
    data/${train_set}_sp_vp_hires exp/nnet3${nnet3_affix}/diag_ubm \
    exp/nnet3${nnet3_affix}/extractor || exit 1;
  #  --num-threads 4 --num-processes 2 \
fi

if [ $stage -le 6 ]; then
  # We extract iVectors on the speed-perturbed training data after combining
  # short segments, which will be what we train the system on.  With
  # --utts-per-spk-max 2, the script pairs the utterances into twos, and treats
  # each of these pairs as one speaker; this gives more diversity in iVectors..
  # Note that these are extracted 'online'.

  # note, we don't encode the 'max2' in the name of the ivectordir even though
  # that's the data we extract the ivectors from, as it's still going to be
  # valid for the non-'max2' data, the utterance list is the same.

  # ivectordir=exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_vp_hires
  ivectordir=data/${train_set}_sp_vp_hires/ivectors
 
  # having a larger number of speakers is helpful for generalization, and to
  # handle per-utterance decoding well (iVector starts at zero).
  temp_data_root=${ivectordir}
  utils/data/modify_speaker_info.sh --utts-per-spk-max 2 \
    data/${train_set}_sp_vp_hires ${temp_data_root}/${train_set}_sp_vp_hires_max2

fi

if [ $stage -le 7 ]; then
  njobs=$(($(nproc)-1))
  n_speakers_test=$(cat ${temp_data_root}/${train_set}_sp_vp_hires_max2/spk2utt| wc -l)
  if [ $njobs -le $n_speakers_test ]; then
    nj=$njobs
  else
    nj=$n_speakers_test
  fi
  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 40 \
    ${temp_data_root}/${train_set}_sp_vp_hires_max2 \
    exp/nnet3${nnet3_affix}/extractor $ivectordir

fi

exit 0
