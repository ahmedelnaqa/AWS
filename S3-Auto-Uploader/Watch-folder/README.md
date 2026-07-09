# S3 Auto Uploader (inotify + AWS CLI)

A production‑ready Bash script that **watches a local folder** for new CSV files and **automatically uploads them to an S3 bucket** using the AWS CLI.

- Prevents duplicate uploads (by file name + checksum)
- Handles multiple inotify events safely (atomic locking)
- Logs every upload and skip event
- Moves processed files to `uploaded/` or `duplicated/` folders
- Designed to run as a Linux systemd service for 24/7 operation

---

## ✨ Features

- **Change detection** – uses `inotifywait` (from `inotify-tools`) to react immediately when a file is closed after writing.
- **Checksum‑based dedup** – even if a file with the same name appears again, it's re‑uploaded only if the content actually changed (MD5).
- **Race‑condition‑free** – atomic directory locks ensure a file is never processed twice.
- **Clean audit trail** – `upload_log.txt` records every action with timestamps and checksums.
- **Safe file handling** – successfully uploaded files go to `uploaded/`, duplicates go to `duplicated/`.
- **Service‑ready** – includes a sample systemd unit file for background execution.

---

## 🛠 Requirements

- **Linux** (tested on Linux Mint 22)
- `inotify-tools` (provides `inotifywait`)
- **AWS CLI v2** installed and configured (`aws configure`)
- An existing S3 bucket with write permissions

Install dependencies on Debian/Ubuntu:
```bash
sudo apt update
sudo apt install inotify-tools curl unzip
# Install AWS CLI v2 if not already present:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
