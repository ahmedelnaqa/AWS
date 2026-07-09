```markdown
# S3 Auto Uploader through watch folder

A production‑ready Bash script that watches a local folder for new CSV files and automatically uploads them to an S3 bucket using the AWS CLI.  
Designed to run 24/7 as a Linux systemd service.

---

## Features

- Instant detection – uses `inotifywait` (from `inotify-tools`) to react immediately when a file is closed after writing.
- Checksum‑based dedup – files with the same name but different content are re‑uploaded; identical files are skipped.
- Atomic locking – prevents race conditions when multiple `inotify` events fire for the same file.
- Clean audit log – `upload_log.txt` records every upload and skip event with timestamps and MD5 checksums.
- Auto‑organisation – uploaded files move to `uploaded/`, duplicates move to `duplicated/`.
- Systemd service example included.

---

## Requirements

- Linux
- `inotify-tools` (provides `inotifywait`)
- AWS CLI v2 installed and configured with access & secret keys 
- An S3 bucket with write permissions

---

## Installation

### 1. Install system dependencies
```bash
sudo apt update
sudo apt install inotify-tools curl unzip -y
```

### 2. Install AWS CLI v2 (if not already installed)
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```
Verify installation:
```bash
aws --version
```

### 3. Configure AWS credentials
```bash
aws configure
```
Provide your `AWS Access Key ID`, `Secret Access Key`, region (e.g., `us-east-1`)

### 4. The Script
If you only need the script, simply create a file `s3_sync.sh` and copy the code from the Full Script section below.

### 5. Edit script variables
Open `s3_sync.sh` and adjust these lines to match your setup:
```bash
WATCH_DIR="/home/(USER_NAME)/data"      # the folder you want to watch
S3_BUCKET="s3://your-bucket-name" # your S3 bucket URL
```

---

## Folder Structure (created automatically though script)

```
/home/(USER_NAME)/data/            ← the watched folder
├── uploaded/                      ← successfully uploaded files
├── duplicated/                    ← duplicates (same content already in S3)
├── upload_log.txt                 ← plain‑text event log
└── .locks/                        ← temporary lock directories (internal)
```

---

## Usage

### Run manually (foreground)
```bash
chmod 700 s3_sync.sh
./s3_sync.sh
```
Open another terminal and drop a test file:
```bash
cp somefile.csv /home/(USER_NAME)/data/
```
Check the terminal running the script – you should see upload confirmation.

### Run as a systemd service (background, auto‑start)

Create the service file:
```bash
sudo nano /etc/systemd/system/s3-uploader.service
```

Paste the following:
```ini
[Unit]
Description=S3 CSV Uploader
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/home/(USER_NAME)/s3_sync.sh
Restart=always
RestartSec=5
User=(USER_NAME)
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/(USER_NAME)/data
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now s3-uploader
systemctl status s3-uploader
```

View real‑time logs:
```bash
journalctl -u s3-uploader -f
```

---

## Full Script (`s3_sync.sh`)

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# VARIABLES – CHANGE THESE TO MATCH YOUR ENVIRONMENT
# ============================================================
WATCH_DIR="/home/(USER_NAME)/data"      # folder to watch
S3_BUCKET="s3://your-bucket-name" # destination S3 bucket
PROCESSED_DIR="$WATCH_DIR/uploaded"
DUPLICATED_DIR="$WATCH_DIR/duplicated"
UPLOAD_LOG="$WATCH_DIR/upload_log.txt"
LOCK_DIR="$WATCH_DIR/.locks"

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

    # Ignore our own administrative files and folders
    [[ "$file" == "upload_log.txt" || "$file" == "uploaded" || "$file" == "duplicated" || "$file" == ".locks" ]] && continue

    src="$WATCH_DIR/$file"
    # Only process regular files
    [ -f "$src" ] || continue

    # ---- ATOMIC LOCK ----
    lockfile="$LOCK_DIR/$file.lock"
    if ! mkdir "$lockfile" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Already processing $file (locked), skipping"
        continue
    fi

    # ---- COMPUTE CHECKSUM ----
    checksum=$(md5sum "$src" | awk '{print $1}')

    # ---- DUPLICATE CHECK ----
    if grep -q " $file $checksum " "$UPLOAD_LOG"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') File $file (same content) already in S3 — skipping"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $file $checksum Skipped" >> "$UPLOAD_LOG"
        if [ -f "$src" ]; then
            mv "$src" "$DUPLICATED_DIR/"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Moved $file → duplicated/"
        fi
        rmdir "$lockfile" 2>/dev/null || true
        continue
    fi

    # ---- NEW / CHANGED FILE ----
    echo "$(date '+%Y-%m-%d %H:%M:%S') Detected: $file (checksum: $checksum)"

    if /usr/local/bin/aws s3 cp "$src" "$S3_BUCKET" --sse aws:kms; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Uploaded: $file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $file $checksum Uploaded" >> "$UPLOAD_LOG"
        if [ -f "$src" ]; then
            mv "$src" "$PROCESSED_DIR/"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Moved: $file → uploaded/"
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') Done"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR uploading $file — left in place for retry"
    fi

    rmdir "$lockfile" 2>/dev/null || true

done
```

---

## Code Explanation

- `set -euo pipefail`  
  Makes the script exit immediately on any error, unset variable, or pipeline failure – essential for reliability.

- Variables  
  All configurable paths and the S3 bucket are defined at the top for easy modification.

- Setup  
  Creates the `uploaded/`, `duplicated/`, and `.locks/` directories if they don’t exist. Also creates an empty log file.

- `inotifywait` loop  
  The script monitors the watch directory forever (`-m`). It triggers on two events:
  - `close_write` – a file was written and closed
  - `moved_to` – a file was moved/renamed into the folder  
  For each filename printed, the loop processes it.

- Ignoring internal files  
  The script immediately skips its own log file and created folders to avoid self‑processing.

- Atomic locking  
  `mkdir` on a lock directory is atomic. If the lock already exists, another event is already handling that file – the current event skips. After processing, the lock is removed.

- Checksum calculation  
  `md5sum` computes a unique fingerprint of the file content. This is used to differentiate files with identical names but different data.

- Duplicate check  
  The script searches the log file for the exact combination of filename and checksum. If found, the file is considered a duplicate, a “Skipped” entry is logged, and the file is moved to `duplicated/`. If not found, it’s uploaded.

- Upload to S3  
  The AWS CLI copies the file with server‑side KMS encryption (`--sse aws:kms`). On success, a “Uploaded” entry is logged and the file moves to `uploaded/`. On failure, the file stays in place for later retry.

- Log format  
  Each line contains: `timestamp filename checksum Status`  
  Example:  
  `2026-07-09 12:24:31 sales.csv d41d8cd98f00b204e9800998ecf8427e Uploaded`

---

## Testing duplicate handling

```bash
# First copy – uploads and moves to uploaded/
cp file.csv /home/(USER_NAME)/data/

# Same file again – skipped and moved to duplicated/
cp file.csv /home/(USER_NAME)/data/

# Modify file content, then copy – re‑uploaded (new checksum)
echo "new row" >> file.csv
cp file.csv /home/(USER_NAME)/data/
```

Check the log:
```bash
cat /home/(USER_NAME)/data/upload_log.txt
```

---

## License

MIT – use freely, modify, and share.

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.
```

Copy the entire block above and save it as `README.md` in your GitHub repository. The script itself is included inside the markdown (under “Full Script”), so users can copy it out and save it as `s3_sync.sh`. Everything is self‑contained – no extra files needed.
