#!/usr/bin/env bash
# Copyright (C) 2026 Masi.net Consulting, LLC <mike+26@masi.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free-Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://gnu.org>.
#
#
# dircheck.sh
#
# Description:
#   A high-performance file integrity tool for large datasets (millions of files, up to 8TB),
#   optimized for low-power devices like Raspberry Pi.
#   - Save mode: Generates hashes for files in a directory tree.
#   - Check mode: Compares current files to previously saved hashes.
#   - Fully NUL-safe format (robust against filenames with spaces, newlines, tabs, Unicode, etc.).
#   - Parallel processing with auto-throttle based on CPU cores, storage type, and system load.
#
# Usage:
#   ./dircheck.sh --follow y|n --hashfunction sha256sum|md5sum|sha1sum \
#       --save savepath pathtocheck [--jobs N]
#
#   ./dircheck.sh --follow y|n --check savepath pathtocheck [--jobs N]
#
# Expected command versions:
#   bash >= 5.0
#   find (GNU findutils) >= 4.7
#   xargs (GNU findutils) >= 4.7
#   coreutils (md5sum/sha1sum/sha256sum) >= 8.30
#
# Notes:
#   - Savefile format is NUL-delimited for safety:
#       First line: "# HASHCMD: <hashfunction>"
#       Subsequent: "<hash>\0<filepath>\0"
#   - Parallel processing tuned via --jobs or automatic throttle.
#

set -euo pipefail
trap 'echo "Error: Command \"$BASH_COMMAND\" failed with exit code $?."' ERR

PARALLEL_JOBS="auto"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# ---- Argument parsing ----
FOLLOW="n"
HASHFUNC=""
SAVEFILE=""
CHECKFILE=""
PATHTOCHECK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --follow) FOLLOW="$2"; shift 2 ;;
        --hashfunction) HASHFUNC="$2"; shift 2 ;;
        --save) SAVEFILE="$2"; shift 2 ;;
        --check) CHECKFILE="$2"; shift 2 ;;
        --jobs) PARALLEL_JOBS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) PATHTOCHECK="$1"; shift ;;
    esac
done

if [[ -z "$PATHTOCHECK" ]]; then
    echo "Error: pathtocheck is required" >&2
    usage
fi

if [[ -n "$SAVEFILE" && -n "$CHECKFILE" ]]; then
    echo "Error: --save and --check cannot be used together" >&2
    exit 1
fi

# ---- Auto-throttle jobs if not specified ----
if [[ "$PARALLEL_JOBS" == "auto" ]]; then
    CORES=$(nproc 2>/dev/null || echo 4)
    PARALLEL_JOBS=$CORES

    # Detect storage type
    ROOT_DEV=$(df "$PATHTOCHECK" | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//')
    if [[ -e "/sys/block/${ROOT_DEV#/dev/}/queue/rotational" ]]; then
        ROT=$(cat "/sys/block/${ROOT_DEV#/dev/}/queue/rotational")
        if [[ "$ROT" == "1" ]]; then
            # Spinning disk → cut parallelism in half
            PARALLEL_JOBS=$((CORES/2))
            (( PARALLEL_JOBS < 1 )) && PARALLEL_JOBS=1
        fi
    fi

    # Adjust further if system load is high
    LOAD=$(awk '{print int($1)}' /proc/loadavg)
    if (( LOAD > CORES )); then
        PARALLEL_JOBS=$((CORES/2))
        (( PARALLEL_JOBS < 1 )) && PARALLEL_JOBS=1
    fi
fi

	PARALLEL_JOBS=1



# ---- Helper functions ----
find_symlink_arg() {
    [[ "$FOLLOW" == "y" ]] && echo "-L" || echo "-P"
}

# ---- SAVE MODE ----
if [[ -n "$SAVEFILE" ]]; then
    if ! command -v "$HASHFUNC" >/dev/null 2>&1; then
        echo "Error: hash function $HASHFUNC not found in PATH" >&2
        exit 1
    fi

    {
        stdbuf -o0 echo "# HASHCMD: $HASHFUNC" 

        find "$(find_symlink_arg)" "$PATHTOCHECK" -type f -print0 | 
        xargs -t -0 -L 1000 -s 4000000 -P "$PARALLEL_JOBS" -I{} "$HASHFUNC" "{}" |
        while IFS= read -r line; do
            hash=$(echo "$line" | awk '{print $1}')
            filepath=$(echo "$line" | cut -d' ' -f2-)
            printf "%s\0%s\0\n" "$hash" "$filepath"
        done
    } > "$SAVEFILE"

    echo "Saved hashes to $SAVEFILE using $PARALLEL_JOBS jobs"
    exit 0
fi

# ---- CHECK MODE ----
if [[ -n "$CHECKFILE" ]]; then
    if [[ ! -f "$CHECKFILE" ]]; then
        echo "Error: Saved checksumfile $CHECKFILE not found" >&2
        exit 
    fi

    HASHFUNC=$(head -n1 "$CHECKFILE" | awk '{print $3}')
    echo "# HASHCMD: $HASHFUNC"
    if ! command -v "$HASHFUNC" >/dev/null 2>&1; then
        echo "Error: hash function $HASHFUNC not found in PATH" >&2
        exit 1
    fi

    TMP_CURRENT=$(mktemp)
    find "$(find_symlink_arg)" "$PATHTOCHECK" -type f -print0 |
    xargs -t -0 -L 1000 -s 4000000 -P "$PARALLEL_JOBS" -I{} "$HASHFUNC" "{}" |
    while IFS= read -r line; do
        hash=$(echo "$line" | awk '{print $1}')
        filepath=$(echo "$line" | cut -d' ' -f2-)
        printf "%s\0%s\0\n" "$hash" "$filepath"
    done > "$TMP_CURRENT"

    TMP_SAVED=$(mktemp)
    tail -c +$(($(head -n1 "$CHECKFILE" | wc -c) + 1)) "$CHECKFILE" > "$TMP_SAVED"

    echo "=== Symlinks not followed ==="
    if [[ "$FOLLOW" == "n" ]]; then
        find "$PATHTOCHECK" -type l
    fi
echo "TMP_SAVED:$TMP_SAVED"
echo "--------------------"

    echo "=== Files deleted ==="
    comm -13 \
        <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_CURRENT" | tr '\0' '\n' | awk 'NR % 2 == 0' | sort) \
        <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_SAVED" | tr '\0' '\n' | awk 'NR % 2 == 0' | sort)

    echo "=== Files added ==="
    comm -23 \
        <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_CURRENT" | tr '\0' '\n' | awk 'NR % 2 == 0' | sort) \
        <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_SAVED" | tr '\0' '\n' | awk 'NR % 2 == 0' | sort)

    echo "=== Files changed ==="
join -t $'\t' -j 2 \
    <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_CURRENT" | tr '\0' '\n' | paste - - | sort -k2,2) \
    <(awk -v RS='\0\n' -v ORS='\0' '1' < "$TMP_SAVED" | tr '\0' '\n' | paste - - | sort -k2,2) |
awk -F $'\t' '$2 != $3 { print $1 "\t" $2 "\t" $3 }'



    echo "Calculating Summary..."

    total=$(tr '\0' '\n' < "$TMP_SAVED" | awk 'NR % 2 == 0' | wc -l)
    changed=$(join -t $'\0\n' -j 2 \
        <(tr '\0' '\n' < "$TMP_CURRENT" | paste - - | sort -z -k2,2) \
        <(tr '\0' '\n' < "$TMP_SAVED"  | paste - - | sort -z -k2,2) |
        awk -F '\0' '$1 != $3' | wc -l)
    percent=$(( 100 * changed / (total == 0 ? 1 : total) ))

    echo "=== Summary ==="
    echo "$total files total"
    echo "$changed changed files"
    echo "$percent% of files changed (using $PARALLEL_JOBS jobs)"

    rm -f "$TMP_CURRENT" "$TMP_SAVED"
    exit 0
fi

#        xargs -0 -P "$PARALLEL_JOBS" -I{} "$HASHFUNC" "{}" ...pipe
#        xargs -0 -P "$PARALLEL_JOBS" -I{} "$HASHFUNC" "{}" ...pipe
