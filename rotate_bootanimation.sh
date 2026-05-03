#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  rotate_bootanimation.sh <input.zip> <output.zip> <rotation> [--no-swap-desc] [--keep-temp]

Arguments:
  input.zip    Source bootanimation zip.
  output.zip   Output bootanimation zip.
  rotation     Rotation angle in degrees: 90, 180, or 270.

Options:
  --no-swap-desc  Do not swap WIDTH/HEIGHT in desc.txt first line for 90/270 rotation.
  --keep-temp     Keep temporary working directory for inspection.

Notes:
  - Requires ImageMagick ("magick" or "convert"), unzip, and zip.
  - Repackages output with STORE mode (-0), as expected by bootanimation.
  - Rotates image frames in directories declared by desc.txt (p/c lines).
    If desc.txt is missing/unparseable, falls back to top-level part* dirs.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

INPUT_ZIP="$1"
OUTPUT_ZIP="$2"
ROTATION="$3"
shift 3

SWAP_DESC=1
KEEP_TEMP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-swap-desc)
            SWAP_DESC=0
            ;;
        --keep-temp)
            KEEP_TEMP=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

case "$ROTATION" in
    90|180|270) ;;
    *) die "Rotation must be one of: 90, 180, 270" ;;
esac

[[ -f "$INPUT_ZIP" ]] || die "Input file not found: $INPUT_ZIP"

need_cmd unzip
need_cmd zip
need_cmd awk
need_cmd find

if command -v magick >/dev/null 2>&1; then
    IM_CMD=(magick)
elif command -v convert >/dev/null 2>&1; then
    IM_CMD=(convert)
else
    die "ImageMagick not found (need 'magick' or 'convert')"
fi

TMP_DIR="$(mktemp -d)"
WORK_DIR="$TMP_DIR/work"

cleanup() {
    if [[ "$KEEP_TEMP" -eq 1 ]]; then
        echo "Temp dir kept: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
unzip -q "$INPUT_ZIP" -d "$WORK_DIR"

DESC_FILE="$WORK_DIR/desc.txt"
declare -a PART_DIRS=()

if [[ -f "$DESC_FILE" ]]; then
    while IFS= read -r part_dir; do
        [[ -n "$part_dir" ]] || continue
        PART_DIRS+=("$part_dir")
    done < <(awk '$1 ~ /^[pc]$/ && NF >= 4 {print $4}' "$DESC_FILE" | sort -u)
fi

if [[ "${#PART_DIRS[@]}" -eq 0 ]]; then
    while IFS= read -r -d '' dir_path; do
        PART_DIRS+=("${dir_path#"$WORK_DIR"/}")
    done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -name 'part*' -print0 | sort -z)
fi

[[ "${#PART_DIRS[@]}" -gt 0 ]] || die "Could not find animation frame directories."

ROTATED_COUNT=0

for rel_dir in "${PART_DIRS[@]}"; do
    abs_dir="$WORK_DIR/$rel_dir"
    [[ -d "$abs_dir" ]] || continue

    if [[ -f "$abs_dir/trim.txt" ]]; then
        echo "Warning: $rel_dir/trim.txt exists; rotation may require trim regeneration." >&2
    fi

    while IFS= read -r -d '' img; do
        "${IM_CMD[@]}" "$img" -rotate "$ROTATION" "$img"
        ROTATED_COUNT=$((ROTATED_COUNT + 1))
    done < <(find "$abs_dir" -type f \( \
        -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \
    \) -print0)
done

[[ "$ROTATED_COUNT" -gt 0 ]] || die "No image frames found to rotate."

if [[ -f "$DESC_FILE" && "$SWAP_DESC" -eq 1 ]]; then
    if [[ "$ROTATION" == "90" || "$ROTATION" == "270" ]]; then
        awk '
            NR == 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
                t = $1; $1 = $2; $2 = t;
            }
            { print }
        ' "$DESC_FILE" > "$DESC_FILE.tmp"
        mv "$DESC_FILE.tmp" "$DESC_FILE"
    fi
fi

OUTPUT_DIR="$(dirname "$OUTPUT_ZIP")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_ABS="$(cd "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_ZIP")"

(
    cd "$WORK_DIR"
    find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -0 -X -q "$OUTPUT_ABS" -@
)

echo "Done."
echo "Input:   $INPUT_ZIP"
echo "Output:  $OUTPUT_ABS"
echo "Rotated frames: $ROTATED_COUNT"
