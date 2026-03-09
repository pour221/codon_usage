#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

if [ "$#" -ne 1 ]; then
    echo "Usage: bash preprocessing.sh <genomes_dir>
Note: use absolute path"
    exit 1
fi

CPUS=10

if [ ! -d "$1" ]; then
    echo "[ERROR] input directory does not exist: $1" >&2
    exit 1
fi

FASTA_DIR="$1"
fasta_files=(
    "$FASTA_DIR"/*.fasta
    "$FASTA_DIR"/*.fa
    "$FASTA_DIR"/*.fna
)
count_fasta="${#fasta_files[@]}"

if [[ $count_fasta -eq 0 ]]; then
    echo "[ERROR] no FASTA files found in $FASTA_DIR" >&2
    exit 1
fi
echo "[INFO] $count_fasta fasta files were detected"

WORKDIR="$(dirname "$FASTA_DIR")"

echo "[PROGRESS] Configure environment"

echo "[INFO] working directory set as $WORKDIR"

PROKKA_RES_DIR="$WORKDIR/prokka"
FFN_DIR="$WORKDIR/ffn"
FREQ_DIR="$WORKDIR/freq"
KMERS_DIR="$WORKDIR/kmers"

dirs=("$PROKKA_RES_DIR" "$FFN_DIR" "$FREQ_DIR" "$KMERS_DIR")

for dir in "${dirs[@]}"; do 
    mkdir -p "$dir"
    echo "[INFO] directory created: $dir"
done

echo "[PROGRESS] Checking dependencies"
necessary_tools=(seqkit prokka cusp mash)

get_version() {
    local tool="$1"

    case "$tool" in
        seqkit) seqkit version 2>&1 | head -n1 ;;
        prokka) prokka --version 2>&1 | head -n1 ;;
        mash) mash --version 2>&1 | head -n1 ;;
        cusp) cusp -version 2>&1 | head -n1 ;;
        *) return 1 ;;
    esac
}
for tool in "${necessary_tools[@]}"; do
    if ! tool_path="$(command -v "$tool")"; then
        echo "[ERROR] required tool '$tool' not found in PATH" >&2
        exit 1
    fi

    version="$(get_version "$tool")"
    echo "[INFO] $tool seems OK: $version ($tool_path)"
done

echo "[PROGRESS] Start QC"
seqkit stats -a "${fasta_files[@]}" > "$WORKDIR/assembly_stats.tsv"

echo "[PROGRESS] Start prokka annotation"
for fasta in "${fasta_files[@]}"; do
    sample_name="$(basename "$fasta")"
    case "$fasta" in
        *.fasta) sample_name="${sample_name%.fasta}" ;;
        *.fa)    sample_name="${sample_name%.fa}" ;;
        *.fna)   sample_name="${sample_name%.fna}" ;;
    esac
    prokka "$fasta" --outdir "$PROKKA_RES_DIR/$sample_name" --prefix "$sample_name" --cpus "$CPUS"
done

echo "[PROGRESS] Collect ffn files"
cp "$PROKKA_RES_DIR"/*/*.ffn "$FFN_DIR"/

ffn_files=("$FFN_DIR"/*.ffn)
if [[ ${#ffn_files[@]} -eq 0 ]]; then
    echo "[ERROR] no .ffn files found after Prokka step" >&2
    exit 1
fi

echo "[PROGRESS] Count CDS"
(
    cd "$FFN_DIR"
    grep -c "^>" "$FFN_DIR"/*.ffn > "$WORKDIR/cds.txt"
)

echo "[PROGRESS] Calculate codon usage with cusp"
for ffn in "$FFN_DIR"/*.ffn; do
    sample_name="$(basename "$ffn" .ffn)"
    cusp -sequence "$ffn" -outfile "$FREQ_DIR/$sample_name.tsv"
done

echo "[PROGRESS] Calculate mash distance"
mash sketch -k 21 -o "$KMERS_DIR/genomes" "${fasta_files[@]}"
mash dist "$KMERS_DIR/genomes.msh" "$KMERS_DIR/genomes.msh" > "$KMERS_DIR/mash.dist.tsv"
echo "[PROGRESS] Done."