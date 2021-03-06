#!/bin/bash

# Script to build and evaluate probabilistic transcriptions.

# This script is split into 15 stages.
# See $startstage and $endstage in the settings file.
# Although stages 9-13 are very fast, we keep them as separate stages
# for tuning hyper-parameters such as # of phone deletions/insertions,
# and because they *are* functionally distinct.

# If the settings file has mcasr=1, then for each short mp3 clip this reads,
# instead of English-letter transcriptions,
# mcasr/s5c/data/LANGUAGE/lang/phones.txt phone-string transcriptions
# computed by https://github.com/uiuc-sst/mcasr.

# To show debug info, export DEBUG=yes.
export DEBUG=no
[ "$DEBUG"==yes ] || set -x

SCRIPTPATH=$(dirname $(readlink --canonicalize-existing $0))
SRCDIR=$SCRIPTPATH/steps
UTILDIR=$SCRIPTPATH/util

export INIT_STEPS=$SRCDIR/init.sh
. $INIT_STEPS

# config.sh is in the local directory, which might differ from that of run.sh.
# If there's no config.sh, that's still okay if binaries are already in $PATH.
if [ -s config.sh ]; then
  . config.sh
  export PATH=$PATH:$OPENFSTDIR:$CARMELDIR:$KALDIDIR
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$OPENFSTLIB1:$OPENFSTLIB2 # for libfstscript.so and libfst.so
fi

if ! hash compute-wer 2>/dev/null; then
  read -p "Enter the Kaldi directory containing compute-wer: " KALDIDIR
  # Typical values:
  # foo/kaldi-trunk/src/bin
  # Append this value, without erasing any previous values.
  echo KALDIDIR=\"$KALDIDIR\" >> config.sh
fi

if ! hash carmel 2>/dev/null; then
  read -p "Enter the directory containing carmel: " CARMELDIR
  # Typical values:
  # foo/bin-carmel/linux64
  # $HOME/carmel/linux64
  echo CARMELDIR=\"$CARMELDIR\" >> config.sh
fi

if ! hash fstcompile 2>/dev/null; then
  read -p "Enter the directory containing fstcompile and other OpenFST programs (/foo/bar/.../bin/.libs): " OPENFSTDIR
  # Typical values:
  # foo/openfst-1.5.0/src/bin/.libs
  echo OPENFSTDIR=\"$OPENFSTDIR\" >> config.sh
  # Expect to find libfstscript.so and libfst.so relative to OPENFSTDIR.
  # foo/openfst-1.5.0/src/bin/.libs becomes
  # foo/openfst-1.5.0/src/lib/.libs and
  # foo/openfst-1.5.0/src/script/.libs
  OPENFSTLIB1=$(echo $OPENFSTDIR | sed 's_bin/.libs$_lib/.libs_')
  OPENFSTLIB2=$(echo $OPENFSTDIR | sed 's_bin/.libs$_script/.libs_')
  echo OPENFSTLIB1=\"$OPENFSTLIB1\" >> config.sh
  echo OPENFSTLIB2=\"$OPENFSTLIB2\" >> config.sh
fi

export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$OPENFSTLIB1:$OPENFSTLIB2 # for libfstscript.so and libfst.so
export PATH=$PATH:$SRCDIR:$UTILDIR:$OPENFSTDIR:$CARMELDIR:$KALDIDIR

if [ ! -d $DATA ]; then
  if [ -z ${DATA_URL+x} ]; then
    echo "Missing DATA directory '$DATA', and no \$DATA_URL to get it from. Check $1."; exit 1
  fi
  tarball=$(basename $DATA_URL)
  # $DATA_URL is e.g. http://www.ifp.illinois.edu/something/foo.tgz
  # $tarball is foo.tgz
  if [ -f $tarball ]; then
    echo "Found tarball $tarball, previously downloaded from $DATA_URL."
  else
    echo "Downloading $DATA_URL."
    wget --no-verbose $DATA_URL || exit 1
  fi
  # Check the name of the tarball's first file (probably a directory).  Strip the trailing slash.
  tarDir=$(tar tvf $tarball | head -1 | awk '{print $NF}' | sed -e 's_\/$__')
  [ "$tarDir" == "$DATA" ] || { echo "Tarball $tarball contains $tarDir, not \$DATA '$DATA'."; exit 1; }
  echo "Extracting $tarball, hopefully into \$DATA '$DATA'."
  tar xzf $tarball || { echo "Unexpected contents in $tarball.  Aborting."; exit 1; }
  [ -d $DATA ] || { echo "Still missing DATA directory '$DATA'. Check $DATA_URL and $1."; exit 1; }
  echo "Installed \$DATA '$DATA'."
fi
[ -d $DATA ] || { echo "Still missing DATA directory '$DATA'. Check $DATA_URL and $1."; exit 1; }
[ -d $LISTDIR ] || { echo "Missing LISTDIR directory $LISTDIR. Check $1."; exit 1; }
[ -d $TRANSDIR ] || { echo "Missing TRANSDIR directory $TRANSDIR. Check $1."; exit 1; }
[ -d $TURKERTEXT ] || { echo "Missing TURKERTEXT directory $TURKERTEXT. Check $1."; exit 1; }
[ -s $engdict ] || { echo "Missing or empty engdict file $engdict. Check $1."; exit 1; }
[ -s $engalphabet ] || { echo "Missing or empty engalphabet file $engalphabet. Check $1."; exit 1; }
[ ! -z $phnalphabet ] || { echo "No variable phnalphabet in file '$1'."; exit 1; }
[ -s $phnalphabet ] || { echo "Missing or empty phnalphabet file $phnalphabet. Check $1."; exit 1; }
[ -s $phonelm ] || { echo "Missing or empty phonelm file $phonelm. Check $1."; exit 1; }
[ -z $applyPrepared ] || { echo "Run apply.sh instead of run.sh, because variable \$applyPrepared is set."; exit 1; }

mktmpdir

if [ -d $EXPLOCAL ]; then
  >&2 echo "Using experiment directory $EXPLOCAL."
else
  >&2 echo "Creating experiment directory $EXPLOCAL."
  mkdir -p $EXPLOCAL
fi
cp $1 $EXPLOCAL/settings

[ ! -z $startstage ] || startstage=1
[ ! -z $endstage ] || endstage=99999
echo "Running stages $startstage through $endstage."

if [[ $startstage -le 2 && 2 -le $endstage ]]; then
  hash compute_turker_similarity 2>/dev/null || { echo >&2 "Missing program 'compute_turker_similarity'. First \"cd PTgen/src; make\"."; exit 1; }
fi
if [[ $startstage -le 8 && 8 -le $endstage ]]; then
  hash carmel 2>/dev/null || { echo >&2 "Missing program 'carmel'. Stage 8 would abort.  Please install it from www.isi.edu/licensed-sw/carmel."; exit 1; }
fi
if [[ $startstage -le 15 && 15 -le $endstage ]]; then
  hash compute-wer 2>/dev/null || { echo >&2 "Missing program 'compute-wer'. Stage 15 would abort."; exit 1; }
fi

## STAGE 1 ##
# Preprocess transcripts from crowd workers.
# Creates the file $transcripts, e.g. Exp/uzbek/transcripts.txt.
# (Interspeech paper, figure 1, y^(i)).
SECONDS=0
stage=1
set -e
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
    if [[ -n $mcasr ]]; then
	# Copies preprocessed transcripts from crowd workers.
	# Reads the files $SCRIPTPATH/mcasr/*.txt.
	[ ! -z $LANG_CODE ] || { >&2 echo "No variable LANG_CODE in file '$1'."; exit 1; }
	[ -s $SCRIPTPATH/mcasr/stage1-$LANG_CODE.txt ] || { >&2 echo "Missing or empty file $SCRIPTPATH/mcasr/stage1-$LANG_CODE.txt. Check $1."; exit 1; }
	mkdir -p $(dirname $transcripts)
	cp $SCRIPTPATH/mcasr/stage1-$LANG_CODE.txt $transcripts
	cat $SCRIPTPATH/mcasr/stage1-sbs.txt >> $transcripts
	echo "Stage 1 collected transcripts $SCRIPTPATH/mcasr/stage1-$LANG_CODE.txt and $SCRIPTPATH/mcasr/stage1-sbs.txt."
	echo "Stage 1 took" $SECONDS "seconds."; SECONDS=0
    else
	# Reads the files $engdict and $TURKERTEXT/*/batchfile, where * covers $ALL_LANGS.
	# Uses the variable $rmprefix, if defined.
	mkdir -p $(dirname $transcripts)
	showprogress init 1 "Preprocessing transcripts"
	for L in "${ALL_LANGS[@]}"; do
	  [[ -z $rmprefix ]] || prefixarg="--rmprefix $rmprefix"
	  preprocess_turker_transcripts.pl --multiletter $engdict $prefixarg < $TURKERTEXT/$L/batchfile
	  showprogress go
	done > $transcripts
	showprogress end
	echo "Stage 1 took" $SECONDS "seconds."; SECONDS=0
    fi
else
	usingfile $transcripts "preprocessed transcripts"
fi
set +e

## STAGE 2 ##
# For each utterance, rank each transcript by its similarity to the
# other transcripts (Interspeech paper, section 3).
#
# Reads the file $transcripts.
# Creates the file $simfile, which is read by stage 4's steps/mergetxt.sh.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo -n "Creating transcript similarity scores... "
	mkdir -p $(dirname $simfile)
	compute_turker_similarity < $transcripts > $simfile
	>&2 echo "Done."
	echo "Stage 2 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $simfile "transcript similarity scores"
fi

## STAGE 3 ##
# Prepare data lists.
#
# Via $langmap, expand variable $TRAIN_LANG's abbreviations into full language names.
# Reads each $LISTDIR/language_name/{train, dev, test}.
# Creates the files $trainids, $testids, $adaptids.
# Splits those files into parts {$splittrainids, $splittestids, $splitadaptids}.xxx, where xxx is numbers.
#
# The files language_name/{train, dev, test} contain lines such as "arabic_140925_362941-6".
# Each line may point to:
# - a textfile containing a known-good transcription, data/nativetranscripts/arabic/arabic_140925_362941-6.txt
# - many lines in data/batchfiles/AR/batchfile that contain http://.../arabic_140925_362941-6.mp3
#   and one crowdsourced transcription thereof
# - a line in data/nativetranscripts/AR/ref_train: arabic_140925_362941-6 followed by a string of phonemes
# - a line in data/lists/arabic/arabic.txt: arabic_140925_362941-6 followed by either "discard" or "retain"
#
# To split data into train/dev/eval, there is no strategy common to all languages
# (some languages are pre-split, for instance).  For the languages used in the WS15
# workshop, these arabic_... identifiers were extracted from the .mp3 filenames in
# data/batchfiles/*/batchfile, shuffled, and split 2/3, 1/6, 1/6 for train/dev/eval
# (40/10/10 minutes, in the TASLP paper).

set -e
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	case $TESTTYPE in
	dev | eval)  ;;
	*) >&2 echo "The variable \$TESTTYPE must be either 'dev' or 'eval', not '$TESTTYPE'.  Check $1."; exit 1 ;;
	esac
	>&2 echo -n "Splitting training/test data into parallel jobs... "
	datatype='train'   create-datasplits.sh $1
	datatype='adapt'   create-datasplits.sh $1
	datatype=$TESTTYPE create-datasplits.sh $1
	>&2 echo "Done."
	echo "Stage 3 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $(dirname $splittestids) "test & train ID lists in"
fi

## STAGE 4 ##
# For each utterance ($uttid), merge all of its transcriptions.
#
# Creates file $aligndist, e.g. Exp/uzbek/aligndists.txt.
# Creates directory $mergedir and files therein:
# language_xxx.txt, part-x-language_xxx.txt, $uttid.txt
# (Interspeech paper, section 2.1).
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	mergetxt.sh $1
	echo "Stage 4 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $mergedir "merged transcripts in"
fi

## STAGE 5 ##
# Convert each merged transcript into a sausage, "a confusion network rho(lambda|T)
# over representative transcripts in the annotation-language orthography,"
# "an orthographic confusion network."
#
# Uses variable $alignertofstopt.
# Reads files $mergedir/*.
# Reads files {$splittrainids, $splittestids, $splitadaptids}.xxx.
# Creates directory $mergefstdir and, therein, for each uttid,
# a transcript FST *.M.fst over the English letters $engalphabet
# (IEEE TASLP paper, fig. 4, left side).
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	mergefst.sh $1
	echo "Stage 5 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $mergedir "merged transcript FSTs in"
fi

## STAGE 6 ##
# Initialize the phone-2-letter model, P, aka:
# - the "mismatched channel" of the Interspeech paper, paragraph below table 1.
#
# - the "misperception G2P rho(lambda|phi)" of the TASLP paper, section III.B.
#
# - A model of the probability that an American listener writes a given letter,
# upon hearing a given foreign phoneme.  It assumes that what matters is
# only the American ear, not the utterance's language.  Thus we can learn
# p(letter|phoneme) by using phones from many languages, which cover all
# of the phones in the utterance's language.  Then we compute
#     Phone sequence = arg max  prod_n  p(letter_n | phone_n)
# where p(letter_n | phone_n) is the size-1 version of the mismatch channel.
# Given that phone sequence, we compute
#     Word sequence  = arg max  prod_n  p(phone_n | word that spans phones including phone n)
# where p(phone_n | word that spans phones) = 1 (0) if phone_n is (isn't) part of the word.
# So this model is just a dictionary specifying which phone sequence
# should be considered to correspond to each possible word.  We get this
# dictionary in two steps: (1) assume that the words specified by a machine
# translation engine are the *only* possible words; (2) for each such word,
# convert the sequence of graphemes into a sequence of phones using e.g.
# http://isle.illinois.edu/sst/data/g2ps/Uyghur/Uyghur_Arabic_orthography_dict.html .
#
# Uses variables $Pstyle, $carmelinitopt and $delimsymbol.
# Reads files $phnalphabet and $engalphabet.
# Creates file $initcarmel, e.g. Exp/uzbek/carmel/simple.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo -n "Creating untrained phone-2-letter model ($Pstyle style)... "
	mkdir -p $(dirname $initcarmel)
	create-initcarmel.pl $carmelinitopt $phnalphabet $engalphabet $delimsymbol > $initcarmel
	>&2 echo "Done."
	echo "Stage 6 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $initcarmel "untrained phone-2-letter model"
fi

## STAGE 7 ##
# Create training data to learn the phone-2-letter mappings defined in P.
#
# Reads files $TRANSDIR/$TRAIN_LANG[*]/ref_train.
# Concatenates them into temporary file $reffile (Exp/mandarin/ref_train_text).
# Creates file $carmeltraintxt (Exp/mandarin/carmel/training.txt).
#
# In each ref_train file, each line is an identifier followed by a sequence of phonemes,
# given by passing the transcription through a G2P converter or a dictionary.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo "Creating carmel training data... "
	prepare-phn2let-traindata.sh $1 > $carmeltraintxt
	echo "Stage 7 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $carmeltraintxt "training text for phone-2-letter model"
fi
set +e

## STAGE 8 ##
# EM-train P.
#
# Reads files $carmeltraintxt (Exp/mandarin/training.txt) and $initcarmel (Exp/mandarin/carmel/simple).
# Creates logfile $tmpdir/carmelout.
# Creates file $initcarmel.trained (Exp/mandarin/carmel/simple.trained).
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo -n "Training phone-2-letter model (see $tmpdir/carmelout)..."
	# Read a list of I/O pairs, e.g. Exp/russian/carmel/simple.
	# This list is pairs of lines; each pair is an input sequence followed by an output sequence.
	# Rewrite this list as an FST with new weights, e.g. Exp/russian/carmel/simple.trained.
	#   -f 1 does Dirichlet-prior smoothing.
	#   -M 20 limits training iterations to 20.
	#   -HJ formats output.
	#
	#   "coproc" runs carmel in a parallel shell whose stdout we can grep,
	#   to kill it when it prints something that shows that it's about to
	#   get stuck in an infinite loop.
	# Or:
	#   sudo apt-get install expect;
	#   carmel | tee carmelout | expect -c 'expect -timeout -1 "No derivations"
	coproc { carmel -\? --train-cascade -t -f 1 -M 20 -HJ $carmeltraintxt $initcarmel 2>&1 | tee $tmpdir/carmelout; }
	grep -q -m1 "No derivations in transducer" <&${COPROC[0]} && \
	  [[ $COPROC_PID ]] && kill -9 $COPROC_PID && \
	  >&2 echo -e "\nAborted carmel before it entered an infinite loop..  In settings file, are \$engalphabet and \$phnalphabet compatible with \$mcasr?"
	# Another grep would be "0 states, 0 arcs".
	# The grep obviates the need for an explicit wait statement.
	>&2 echo " Done."

	# Todo: sanity check for carmel's training.
	#
	# Read $initcarmel.trained.
	# Split each line at whitespace into tokens.
	# Parse the last token into a float.
	# Sort the floats.
	# Discard the first 10% and last 10%.
	# Compute the standard deviation.
	# If that's less than some threshold, warn that carmel's training was insufficient.
	#
	# Or, more elaborately:
	# Collect each line's third token, the entropy per symbol.
	# If that's close to log(number of maps, e.g. 56),
	# then that symbol's probabilities are too uniform,
	# i.e., that symbol was insufficiently trained.

	echo "Stage 8 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile ${initcarmel}.trained "trained phone-2-letter model"
fi

## STAGE 9 ##
# Convert P to OpenFst format.
#
# Reads file $initcarmel.trained.
# Uses variables $disambigdel, $disambigins, $phneps, and $leteps.
# May use variable $Pscale, to scale P's weights.
# Creates the FST file $Pfst, mapping $phnalphabet to $engalphabet,
# and the corresponding text file $tmpdir/trainedp2let.fst.txt.
#
# This FST has 2 states (0 and 1), and about 6000 arcs:
# - from state 0 to state 0, mapping each phone to each letter, with various weights;
# - one arc from 0 to 1 for special phone "#2", emitting eps;
# - from 1 to 0 mapping phone "#3" to each letter, with various weights;
# - from 1 to 0 mapping all other phones to eps.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	[ -s ${initcarmel}.trained ] || { >&2 echo "Empty ${initcarmel}.trained, so can't create $Pfst. Aborting."; exit 1; }
	if [[ -z $Pscale ]]; then
	  Pscale=1
	fi
	>&2 echo -n "Creating P (phone-2-letter) FST [PSCALE=$Pscale]... "
	convert-carmel-to-fst.pl < ${initcarmel}.trained |
	  sed -e 's/e\^-\([0-9]*\)\..*/1.00e-\1/g' | convert-prob-to-neglog.pl |
	  scale-FST-weights.pl $Pscale |
	  fixp2let.pl $disambigdel $disambigins $phneps $leteps |
	  tee $tmpdir/trainedp2let.fst.txt |
	  fstcompile --isymbols=$phnalphabet --osymbols=$engalphabet > $Pfst
	>&2 echo "Done."
	echo "Stage 9 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $Pfst "P (phone-2-letter) FST"
fi

## STAGE 10 ##
# Prepare the language model FST, G.
#
# Reads files $phnalphabet and $phonelm.
# $phonelm is a bigram phone language model, typically built by sending
# Wikipedia text through a zero-resource knowledge-based G2P (TASLP paper,
# fig. 5 and section IV.C;  http://isle.illinois.edu/sst/data/g2ps/ ).
#
# Uses variables $disambigdel and $disambigins.
# May use variable $Gscale, to scale G's weights.
# Creates the modeled phone bigram probability pi(phi^l | theta)
# $Gfst, over the symbols $phnalphabet (TASLP paper, section IV.C).
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	if [[ -z $Gscale ]]; then
		Gscale=1
	fi
	>&2 echo -n "Creating G (phone-model) FST with disambiguation symbols [GSCALE=$Gscale]... "
	mkdir -p $(dirname $Gfst)
	# Because addloop.pl adds #2 and #3 symbols via settings' disambigdel and disambigins,
	# data/phonesets/univ.compact.txt must include #2 and #3.
	fstprint --isymbols=$phnalphabet --osymbols=$phnalphabet $phonelm \
		| addloop.pl $disambigdel $disambigins \
		| scale-FST-weights.pl $Gscale \
		| fstcompile --isymbols=$phnalphabet --osymbols=$phnalphabet \
		| fstarcsort --sort_type=olabel > $Gfst
	>&2 echo "Done."
	echo "Stage 10 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $Gfst "G (phone model) FST"
fi

## STAGE 11 ##
# Create a prior over letters (explained in create-letpriorfst.pl).
#
# Reads files in directory $mergedir.
# Reads files $trainids and $engalphabet.
# May use variable $Lscale, to scale L's weights.
# Creates file $Lfst, over the symbols $engalphabet.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	[ ! -z $Lscale ] || Lscale=1
	>&2 echo -n "Creating L (letter statistics) FST... "
	mkdir -p $(dirname $Lfst)
	create-letpriorfst.pl $mergedir $trainids \
		| scale-FST-weights.pl $Lscale \
		| fstcompile --osymbols=$engalphabet --isymbols=$engalphabet - \
		| fstarcsort --sort_type=ilabel - > $Lfst
	>&2 echo "Done."
	echo "Stage 11 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $Lfst "L (letter statistics) FST"
fi

## STAGE 12 ##
# Create an auxiliary FST T that restricts the number of phone deletions
# and letter insertions, through tunable parameters Tnumdel and Tnumins.
#
# Uses variables $disambigdel $disambigins $Tnumdel $Tnumins.
# Creates file $Tfst, over the symbols $phnalphabet.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo "Creating T (deletion/insertion limiting) FST... "
	create-delinsfst.pl $disambigdel $disambigins $Tnumdel $Tnumins < $phnalphabet \
		| fstcompile --osymbols=$phnalphabet --isymbols=$phnalphabet - > $Tfst
	>&2 echo "Done."
	echo "Stage 12 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $Tfst "T (deletion/insertion limiting) FST"
fi

## STAGE 13 ##
# Create TPL and GTPL FSTs.
#
# Reads files $Lfst $Tfst $Gfst.
# Creates files $TPLfst and $GTPLfst.
# 
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	>&2 echo -n "Creating TPL and GTPL FSTs... "
	mkdir -p $(dirname $TPLfst)
	fstcompose $Pfst $Lfst | fstcompose $Tfst - | fstarcsort --sort_type=olabel \
		 | tee $TPLfst | fstcompose $Gfst - | fstarcsort --sort_type=olabel > $GTPLfst
	>&2 echo "Done."
	echo "Stage 13 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $GTPLfst "GTPL FST"
fi

## STAGE 14 ##
# Decode.  Create lattices for each merged utterance FST (M),
# both with (GTPLM) and without (TPLM) a language model.
#
# Reads the files $splittestids.xxx or $splitadaptids.xxx.
# Reads the files $mergefstdir/*.M.fst.txt.
# Creates and then reads the files $mergefstdir/*.M.fst.
# Reads the files $GTPLfst and $TPLfst.
# Creates the files $decodelatdir/*.GTPLM.fst and $decodelatdir/*.TPLM.fst
# Creates $decodelatdir.
# Each GTPLM.fst is over $phnalphabet, a lattice over phones.
set -e
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	if [[ -n $makeTPLM && -n $makeGTPLM ]]; then
		msgtext="GTPLM and TPLM"
	elif [[ -n $makeTPLM ]]; then
		msgtext="TPLM"
	elif [[ -n $makeGTPLM ]]; then
		msgtext="GTPLM"
	else
		>&2 echo "Neither makeTPLM nor makeGTPLM is set.  Check $1."
		exit 1
	fi
	>&2 echo -n "Decoding lattices $msgtext"
	mkdir -p $decodelatdir
	decode_PTs.sh $1
	echo "Stage 14 took" $SECONDS "seconds."; SECONDS=0
else
	usingfile $decodelatdir "decoded lattices in"
fi
set +e

## STAGE 15 ##
# Evaluate the GTPLM lattices, stand-alone.
#
# Composing a transcript FST with $Gfst (i.e., the GTPLM's) requires the
# non-event symbol "#2" in $phnalphabet (data/phonesets/univ.compact.txt) for
# self-loops added to $Gfst (TASLP paper, fig. 6; section IV.C, last paragraph).
#
# Reads files $splittestids.xxx $evalreffile $phnalphabet $decodelatdir/*.GTPLM.fst $testids.
# Uses variables $evaloracle $prunewt.
# May create file $hypfile.
# Creates $evaloutput, the evalution of error rates.
((stage++))
if [[ $startstage -le $stage && $stage -le $endstage ]]; then
	if [[ -n $decode_for_adapt ]]; then
		>&2 echo "Not evaluating PTs (adaptation mode)."
	else
		evaluate_PTs.sh $1 | tee $evaloutput >&2
		echo "Stage 15 took" $SECONDS "seconds."; SECONDS=0
	fi
else
	>&2 echo "Stage 15: nothing to do."
fi

if [ -z $debug ]; then
	rm -rf $tmpdir
fi
