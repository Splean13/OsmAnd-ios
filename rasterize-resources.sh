#!/bin/bash

echo "Checking for bash..."
if [ -z "$BASH_VERSION" ]; then
	echo "Invalid shell, re-running using bash..."
	exec bash "$0" "$@"
	exit $?
fi
SRCLOC="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Find rsvg-convert
if [ -z "$RSVG_CONVERT" ]; then 
	RSVG_CONVERT=`which rsvg-convert`
fi
if [ -z "$RSVG_CONVERT" ]; then 
	echo "rsvg-convert tool not found"
	exit 1
fi
echo "Using $RSVG_CONVERT..."
export RSVG_CONVERT

# Remove previous
rm -rf "$SRCLOC/Resources/Rasterized"

# Rasterize resources
rasterize_resource() {
	ORIGIN="$(pwd)/.."
	INPUT_FILENAME="${1##*/}"
	INPUT_FORMAT="${INPUT_FILENAME##*.}"
	FILENAME="${INPUT_FILENAME%.*}"
	OUTPUT_FILENAME="${FILENAME}.png"
	SUBPATH="${1%/*}"
	INPUT="Resources.svg/$SUBPATH/$INPUT_FILENAME"
	OUTPUT="Resources/Rasterized/$SUBPATH/$OUTPUT_FILENAME"
	OUTPUT_PATH="$ORIGIN/Resources/Rasterized/$SUBPATH"
	echo "Rasterizing '$FILENAME' (\"$SUBPATH\")"
	mkdir -p "$OUTPUT_PATH"
	
	# Rasterize this version as 1:1 version
	(cd "$ORIGIN" && $RSVG_CONVERT -f png -o "$OUTPUT" "$INPUT")
	
	# If original is 1x scale, ...
	if ! [[ "$FILENAME" =~ @2x$ ]]; then
		# ... and there's no source version that provides 2x, rasterize larger version
		if [ ! -f "$ORIGIN/Resources.svg/$SUBPATH/${FILENAME}@2x.${INPUT_FORMAT}" ]; then
			echo -n -e "\t"
			echo "+ 2x"
			(cd "$ORIGIN" && $RSVG_CONVERT -z 2 -f png -o "$OUTPUT_PATH/${FILENAME}@2x.png" "$INPUT")
		fi
	fi
	
	# If original is 2x scale, ...
	if [[ "$FILENAME" =~ @2x$ ]]; then
		# ... and there's no source version that provides 1x, rasterize smaller version
		if [ ! -f "$ORIGIN/Resources.svg/$SUBPATH/${FILENAME%@2x}.${INPUT_FORMAT}" ]; then
			echo -n -e "\t"
			echo "+ 0.5x"
			(cd "$ORIGIN" && $RSVG_CONVERT -z 0.5 -f png -o "$OUTPUT_PATH/${FILENAME%@2x}.png" "$INPUT")
		fi
	fi
	
	return $?
}
export -f rasterize_resource
(cd "$SRCLOC/Resources.svg" && \
	find . -type f -name "*.svg" -exec bash -c 'rasterize_resource "$@"' _ {} \;)
