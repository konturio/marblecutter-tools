#!/usr/bin/env bash

transcode_args=""

OPTIND=1

while getopts "h?r:v" opt; do
  case "$opt" in
    h|\?)
      usage
      exit 0
      ;;
    r)
      transcode_args="${transcode_args} -r $OPTARG"
      ;;
    v)
      transcode_args="${transcode_args} -v"
      DEBUG=true
      ;;
  esac
done

shift $((OPTIND-1))

input=$1
output=$2
callback_url=$3

# target thumbnail size in KB
THUMBNAIL_SIZE=${THUMBNAIL_SIZE:-300}

# support for S3-compatible services (for GDAL + transcode.sh)
# TODO support AWS_HTTPS to match GDAL
export AWS_S3_ENDPOINT_SCHEME=${AWS_S3_ENDPOINT_SCHEME:-https://}
export AWS_S3_ENDPOINT=$AWS_REGION".s3.amazonaws.com"

if [[ ! -z "$DEBUG" ]]; then
  set -x
fi

set -euo pipefail

failed=0
cleaning=0
to_clean=()

function usage() {
  >&2 echo "usage: $(basename $0) [-r method] [-v] <input> <output basename> [callback URL]"
}

function check_args() {
  if [[ -z "$input" || -z "$output" ]]; then
    # input is an HTTP-accessible GDAL-readable image
    # output is an S3 URI or file prefix (i.e. w/o extensions)
    # e.g.:
    #   bin/process.sh \
    #   http://hotosm-oam.s3.amazonaws.com/uploads/2016-12-29/58655b07f91c99bd00e9c7ab/scene/0/scene-0-image-0-transparent_image_part2_mosaic_rgb.tif \
    #   s3://oam-dynamic-tiler-tmp/sources/58655b07f91c99bd00e9c7ab/0/58655b07f91c99bd00e9c7a6
    usage
    exit 1
  fi
}

function cleanup() {
  # prevent double-cleanup
  if [[ $cleaning -eq 0 ]]; then
    cleaning=1
    for f in ${to_clean[@]}; do
      rm -f "${f}"
    done
  fi
}

function update_status() {
  set +u

  local status=$1
  local message=$2

  >&2 echo "#*{ \"status\": \"${status}\", \"message\": \"${message}\" }*#"

  set -u
}

function mark_failed() {
  if [[ ! -z "$callback_url" ]]; then
    echo "Failed. Telling ${callback_url}"
    update_status failed
  fi
}

function cleanup_on_failure() {
  # prevent double-cleanup
  if [[ $failed -eq 0 ]]; then
    failed=1
    # mark as failed
    mark_failed

    local s3_outputs=(${output}.tif ${output}.json ${output}.png)

    if [[ "$output" =~ ^s3:// ]]; then
      set +e
      for x in ${s3_outputs[@]}; do
        aws s3 rm --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $x 2> /dev/null
      done
      set -e
    fi

    cleanup
  fi
}

function download() {
  local input=$1
  local source=$2

  if [[ "$input" =~ ^s3:// ]]; then
    echo "Downloading $input from S3..."
    update_status status "Downloading $input from S3..."
    aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} "$input" "$source"
  elif [[ "$input" =~ s3\.amazonaws\.com ]]; then
    echo "Downloading $input from S3 over HTTP..."
    update_status status "Downloading $input from S3 over HTTP..."
    curl -sfSL "$input" -o "$source" || { 
      retval=$?
      if [ $retval -eq 22 ]; then
        cleanup_on_failure $LINENO
        exit 1
      fi
    }
  elif [[ "$input" =~ ^https?:// && ! "$input" =~ s3\.amazonaws\.com ]]; then
    echo "Downloading $input..."
    update_status status "Downloading $input..."
    curl -sfSL "$input" -o "$source" || { 
      retval=$?
      if [ $retval -eq 22 ]; then
        cleanup_on_failure $LINENO
        exit 1
      fi
    }
  else
    cp "$input" "$source"
  fi

  to_clean+=($source)
}

check_args

# register signal handlers
trap cleanup EXIT
trap cleanup_on_failure INT
trap cleanup_on_failure ERR

__dirname=$(cd $(dirname "$0"); pwd -P)
PATH=$__dirname:$PATH
filename=$(basename "$input")
base=$(mktemp)
to_clean+=($base)
source="${base}.${filename%%\?*}"
intermediate=${base}-intermediate.tif
to_clean+=($intermediate ${source}.aux.xml)
gdal_output=$(sed 's|s3://\([^/]*\)/|/vsis3/\1/|' <<< $output)

echo "Processing ${input} into ${output}.{json,png,tif}..."
update_status processing

# 0. download source

download "$input" "$source"

if [[ "$input" =~ \.img ]]; then
  set +e

  echo "Attempting to download .ige companion..."
  download "${input/%.img/.ige}" "${source/%.img/.ige}"

  set -e
fi

# 1. transcode + generate overviews
transcode.sh $transcode_args $source $intermediate $callback_url

# keep local sources
if [[ "$input" =~ ^(s3|https?):// ]]; then
  rm -f $source
fi

# 6. create thumbnail
echo "Generating thumbnail..."
update_status status "Generating thumbnail..."
thumb=${base}.png
to_clean+=($thumb ${thumb}.aux.xml ${thumb}.msk)
info=$(rio info $intermediate 2> /dev/null)
count=$(jq .count <<< $info)
colorinterp=$(jq .colorinterp <<< $info)
mask_flags=$(jq -c .mask_flags <<< $info)
height=$(jq .height <<< $info)
width=$(jq .width <<< $info)
target_pixel_area=$(bc -l <<< "$THUMBNAIL_SIZE * 1000 / 0.75")
ratio=$(bc -l <<< "sqrt($target_pixel_area / ($width * $height))")
target_width=$(printf "%.0f" $(bc -l <<< "$width * $ratio"))
target_height=$(printf "%.0f" $(bc -l <<< "$height * $ratio"))

bands=""
for b in $(seq 1 $count); do
  if [ "$(jq -r ".[$[b - 1]]" <<< $colorinterp)" != "palette" ]; then
    # skip paletted bands; they'll be expanded using their colormap automatically
    bands="$bands -b $b"
  fi
done

if [ -n "$bands" ] && grep -q per_dataset <<< $mask_flags; then
  # bands are mapped and a mask is present
  # no need to fiddle with alpha channels or nodata values as they will have already
  # been converted into a mask
  bands="$bands -b mask,1"
fi

gdal_translate \
  -q \
  $bands \
  -of png \
  $intermediate \
  $thumb \
  -outsize $target_width $target_height

# 5. create footprint
echo "Generating footprint..."
update_status status "Generating footprint..."
info=$(rio info $intermediate)
nodata=$(jq -r .nodata <<< $info)
resolution=$(get_resolution.py $intermediate)

# resample using 'average' so that rescaled pixels containing _some_ values
# don't end up as NODATA (better than sampling with rio shapes for this reason)
if [[ "$nodata" = "null" ]]; then
  gdalwarp \
    -q \
    -r average \
    -ts $[$(jq -r .width <<< $info) / 100] $[$(jq -r .height <<< $info) / 100] \
    $intermediate ${intermediate/.tif/_small.tif}
else
  gdalwarp \
    -q \
    -r average \
    -ts $[$(jq -r .width <<< $info) / 100] $[$(jq -r .height <<< $info) / 100] \
    -srcnodata $(jq -r .nodata <<< $info) \
    $intermediate ${intermediate/.tif/_small.tif}
fi

footprint=${base}.json
to_clean+=($footprint)

small=${intermediate/.tif/_small.tif}
to_clean+=($small)

rio shapes --collection --mask --as-mask --precision 6 ${small} | \
  build_metadata.py \
    --meta \
      url="\"${output}.tif\"" \
      filename="\"$(basename "$output").tif\"" \
      dimensions=$(jq -c '.shape | reverse' <<< $info) \
      bands=$(jq -c .count <<< $info) \
      size=$(stat -c %s "${intermediate}" | cut -f1) \
      dtype=$(jq -c .dtype <<< $info) \
      crs="$(jq -c .crs <<< $info)" \
      projection="\"$(gdalsrsinfo "$(jq -r .crs <<< $info)" -o wkt | sed 's/\"/\\"/g')\"" \
      colorinterp=$(jq -c .colorinterp <<< $info) \
      resolution=$(jq -c .res <<< $info) \
      resolution_in_meters=${resolution} \
      thumbnail="\"${output}.png\"" \
    > $footprint

meta=$(< $footprint)

if [[ "$output" =~ ^s3:// ]]; then

  echo "Uploading..."
  update_status status "Uploading..."
  aws s3 cp $intermediate "${output}.tif"
  aws s3 cp $footprint "${output}.json"
  aws s3 cp $thumb "${output}.png"
else
  mv $intermediate "${output}.tif"
  mv $footprint "${output}.json"
  mv $thumb "${output}.png"
fi

# call web hooks
if [[ ! -z "$callback_url" ]]; then
  >&2 echo "Notifying ${callback_url}"
  curl -s -X POST -d @- -H "Content-Type: application/json" "${callback_url}" <<< $meta
fi

rm -f ${intermediate}*

echo "Done."
