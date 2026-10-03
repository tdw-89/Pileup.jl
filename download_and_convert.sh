#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BAM_LIST="${1:-$SCRIPT_DIR/bam_list.txt}"
CONDA_ENV="${CONDA_ENV:-htslib_env}"
RSYNC_PARTIAL_DIR="${RSYNC_PARTIAL_DIR:-$SCRIPT_DIR/.rsync-partial}"

if [[ ! -f "$BAM_LIST" ]]; then
    printf 'BAM list not found: %s\n' "$BAM_LIST" >&2
    exit 1
fi

# Initialize conda for non-interactive Bash, then use the environment that
# provides samtools. If it is already active, leave the shell as-is.
if [[ "${CONDA_DEFAULT_ENV:-}" != "$CONDA_ENV" ]]; then
    if ! command -v conda >/dev/null 2>&1; then
        printf 'conda is required to activate environment %s\n' "$CONDA_ENV" >&2
        exit 1
    fi
    eval "$(conda shell.bash hook)"
    conda activate "$CONDA_ENV"
fi

for command_name in rsync samtools; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$command_name" >&2
        exit 1
    fi
done

CONVERTER="$SCRIPT_DIR/bam-to-parquet"
if [[ ! -x "$CONVERTER" ]]; then
    printf 'Executable bam-to-parquet not found: %s\n' "$CONVERTER" >&2
    exit 1
fi

mkdir -p -- "$RSYNC_PARTIAL_DIR"

sort_tmp=""
stage_dir=""
cleanup() {
    if [[ -n "$sort_tmp" && -e "$sort_tmp" ]]; then
        rm -f -- "$sort_tmp"
    fi
    if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir"
    fi
}
trap cleanup EXIT

processed=0
skipped=0
while IFS= read -r remote || [[ -n "$remote" ]]; do
    remote="${remote%$'\r'}"
    [[ -z "$remote" || "$remote" == \#* ]] && continue

    if [[ "$remote" != unity:* ]]; then
        printf 'Expected an rsync path prefixed with unity:, got: %s\n' "$remote" >&2
        exit 1
    fi

    remote_path="${remote#unity:}"
    filename="${remote_path##*/}"
    if [[ "$filename" != *.bam || "$filename" == ".bam" ]]; then
        printf 'Expected a .bam path, got: %s\n' "$remote" >&2
        exit 1
    fi

    sample="${filename%.bam}"
    bam_path="$SCRIPT_DIR/$filename"
    sorted_bam="$SCRIPT_DIR/$sample.sorted.bam"
    outdir="$SCRIPT_DIR/$sample"
    stats_file="$outdir/$sample.stats.json"

    # A completed output directory is the restart marker. Do not repeat work;
    # remove BAM intermediates if the prior run was interrupted during cleanup.
    if [[ -d "$outdir" && -s "$stats_file" ]]; then
        shopt -s nullglob
        existing_parquets=("$outdir"/*.parquet)
        shopt -u nullglob
        if (( ${#existing_parquets[@]} > 0 )); then
            printf 'Already converted, skipping: %s\n' "$sample"
            rm -f -- "$bam_path" "$sorted_bam"
            ((skipped += 1))
            continue
        fi
    fi

    if [[ -e "$outdir" ]]; then
        printf 'Output directory exists but is not a completed conversion: %s\n' "$outdir" >&2
        exit 1
    fi

    printf '\n[%s] Downloading %s\n' "$((processed + skipped + 1))" "$remote"
    # Keep partial data in a dedicated directory so a retry can reuse it as
    # the basis for rsync's delta transfer.
    rsync -avP --partial-dir="$RSYNC_PARTIAL_DIR" -- \
        "$remote" "$bam_path"

    header_line="$(samtools view -H "$bam_path" | sed -n '1p')"
    conversion_bam="$bam_path"
    if [[ "$header_line" =~ (^|[[:space:]])SO:coordinate([[:space:]]|$) ]]; then
        printf '[%s] Header declares coordinate sort; skipping samtools sort\n' "$sample"
    else
        printf '[%s] Sorting %s\n' "$sample" "$filename"
        sort_tmp="$(mktemp "$SCRIPT_DIR/.$sample.sorted.XXXXXX")"
        samtools sort --threads 4 -O BAM -o "$sort_tmp" "$bam_path"
        mv -f -- "$sort_tmp" "$sorted_bam"
        sort_tmp=""
        conversion_bam="$sorted_bam"
    fi

    stage_dir="$(mktemp -d "$SCRIPT_DIR/.$sample.parquet.XXXXXX")"
    printf '[%s] Converting BAM to Parquet\n' "$sample"
    "$CONVERTER" --input "$conversion_bam" --outdir "$stage_dir" \
        --basename "$sample" --threads 4

    shopt -s nullglob
    converted_parquets=("$stage_dir"/*.parquet)
    shopt -u nullglob
    if (( ${#converted_parquets[@]} == 0 )) || [[ ! -s "$stage_dir/$sample.stats.json" ]]; then
        printf 'Converter finished without expected Parquet files and stats for %s\n' "$sample" >&2
        exit 1
    fi

    mv -- "$stage_dir" "$outdir"
    stage_dir=""

    # Keep the downloaded BAM and sorted BAM only until this sample converts.
    rm -f -- "$bam_path" "$sorted_bam"
    ((processed += 1))
    printf '[%s] Done; removed local BAM intermediates\n' "$sample"
done < "$BAM_LIST"

printf '\nFinished. Converted %d file(s); skipped %d completed file(s).\n' \
    "$processed" "$skipped"
