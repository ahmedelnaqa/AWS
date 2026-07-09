#!/bin/bash
set -euo pipefail

# ============================================================
# VARIABLES
# ============================================================
WATCH_DIR="/home/(USER_NAME)/data"
S3_BUCKET="s3://bronze-superstore-ds-demouser-483772923600-ap-southeast-4-an"
PROCESSED_DIR="$WATCH_DIR/uploaded"          # successfully uploaded files
DUPLICATED_DIR="$WATCH_DIR/duplicated"       # already‑in‑S3 files
UPLOAD_LOG="$WATCH_DIR/upload_log.txt"       # permanent record
LOCK_DIR="$WATCH_DIR/locks"                 # to avoid race conditions

# ============================================================
# SETUP
# ============================================================
mkdir -p "$PROCESSED_DIR" "$DUPLICATED_DIR" "$LOCK_DIR"
touch "$UPLOAD_LOG"

# ============================================================
# FILE WATCHER
# ============================================================
inotifywait -m "$WATCH_DIR" -e close_write -e moved_to --format '%f' |
while IFS= read -r file; do

    # ---- IGNORE OUR OWN FILES AND DIRECTORIES ----
    [[ "$file" == "upload_log.txt" || "$file" == "uploaded" || "$file" == "duplicated" || "$file" == ".locks" ]] && continue

    src="$WATCH_DIR/$file"
    # Only process regular files (skip directories, symlinks)
    [ -f "$src" ] || continue

    # ---- ATOMIC LOCK TO PREVENT DOUBLE PROCESSING ----
    lockfile="$LOCK_DIR/$file.lock"
    # mkdir is atomic – if it fails, another event is already handling this file
    if ! mkdir "$lockfile" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Already processing $file (locked), skipping"
        continue
    fi
    # Always remove the lock when done (trap ensures it's removed even on error)
    trap "rmdir '$lockfile' 2>/dev/null || true" EXIT

    # ---- COMPUTE CHECKSUM ----
    # Use md5sum (fast, good enough for duplicate detection)
    checksum=$(md5sum "$src" | awk '{print $1}')

    # ---- DUPLICATE CHECK (by filename + checksum) ----
    # Search the log for the same filename and checksum
    if grep -q " $file $checksum " "$UPLOAD_LOG"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') File $file (same content) already in S3 — skipping"
        # Log the skipped event
        echo "$(date '+%Y-%m-%d %H:%M:%S') $file $checksum Skipped" >> "$UPLOAD_LOG"
        # Move to duplicated/ folder (safely)
        if [ -f "$src" ]; then
            mv "$src" "$DUPLICATED_DIR/"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Moved $file → duplicated/"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') $file already moved, nothing to do"
        fi
        rmdir "$lockfile" 2>/dev/null || true
        continue
    fi

    # ---- NEW FILE (or changed content) ----
    echo "$(date '+%Y-%m-%d %H:%M:%S') Detected: $file (checksum: $checksum)"

    # Upload to S3
    if /usr/local/bin/aws s3 cp "$src" "$S3_BUCKET" --sse aws:kms; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Uploaded: $file"
        # Log as Uploaded (with checksum)
        echo "$(date '+%Y-%m-%d %H:%M:%S') $file $checksum Uploaded" >> "$UPLOAD_LOG"

        # Move to uploaded/ folder
        if [ -f "$src" ]; then
            mv "$src" "$PROCESSED_DIR/"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Moved: $file → uploaded/"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') $file already removed (duplicate event), ignoring"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') Done"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR uploading $file — left in place for retry"
    fi

    # Release lock
    rmdir "$lockfile" 2>/dev/null || true

done
