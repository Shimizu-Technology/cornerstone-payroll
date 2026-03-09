#!/usr/bin/env python3
"""
Download all MoSa 2025 payroll email attachments from Gmail.
Saves PDFs and Excel files to data/mosa-2025/raw/
Creates a manifest.json with all download metadata.
"""

import json
import os
import subprocess
import sys

GOG_ACCOUNT = os.environ.get("GOG_ACCOUNT")
GOG_PASSWORD = os.environ.get("GOG_KEYRING_PASSWORD")
OUT_DIR = os.path.expanduser("~/work/cornerstone-payroll/data/mosa-2025/raw")
MANIFEST_PATH = os.path.expanduser("~/work/cornerstone-payroll/data/mosa-2025/manifest.json")

# All 27 forwarded payroll message IDs (from Gmail search)
MESSAGES = [
    ("19ccfcf3422947b6", "Payroll 12/15-12/27"),
    ("19ccfcf1c901c17a", "Payroll 12/1-12/13"),
    ("19ccfcf07bf6f086", "payroll 11/17-11/29"),
    ("19ccfcf002d65ecf", "Payroll 11/3-11/15"),
    ("19ccfcee57be6169", "Payroll 10/20-11/2"),
    ("19ccfcebc21e6d9d", "Mosa's Payroll 9/22-10/4"),
    ("19ccfceaefef098e", "Payroll 9/8-9/20"),
    ("19ccfcea50ca5563", "Payroll 8/25-9/6"),
    ("19ccfce5dbfd847a", "Payroll 8/11-8/23"),
    ("19ccfce528b4a7c5", "Payroll 7/28-8/9"),
    ("19ccfce1f40592d6", "Payroll 6/30-7/12"),
    ("19ccfce1bf44e30e", "Payroll 7/14-7/26"),
    ("19ccfcdf2a97524e", "Payroll 6/16 to 6/28"),
    ("19ccfcdecd024748", "Payroll 6/2-6/15 PD 6/19"),
    ("19ccfcdd353d7067", "Payroll 5/19-5/31"),
    ("19ccfcdadd31bf74", "Payroll 5/5-5/17"),
    ("19ccfcd98e0af9e3", "Payroll 4/21-5/3"),
    ("19ccfcd81c55e151", "Payroll 4/7-4/19"),
    ("19ccfcd80de79348", "Payroll 3/24-4/5"),
    ("19ccfcd65c8b5563", "Payroll 3/10-3/22"),
    ("19ccfcd4431c018a", "Payroll 2/23-3/8"),
    ("19ccfcd2f8c9544f", "Payroll 2/10-2/22"),
    ("19ccfcd18c3f11db", "Payroll 1/27-2/8"),
    ("19ccfcd024d8acc2", "Payroll 1/13-1/25"),
    ("19ccfccadf93a4fe", "Payroll 12/30-1/11"),   # PP1 2025
    ("19ccfcc91ed7a3fc", "Payroll 12/16-12/29"),   # 2024 period
    ("19ccfcc8555945ff", "Payroll 1/12-1/24"),     # possible overlap
]

def run_gog(args):
    env = {**os.environ, "GOG_KEYRING_PASSWORD": GOG_PASSWORD}
    result = subprocess.run(
        ["gog"] + args + ["--account", GOG_ACCOUNT, "--json", "--no-input"],
        capture_output=True, text=True, env=env, timeout=60
    )
    return result

def get_message(msg_id):
    result = run_gog(["gmail", "get", msg_id])
    if result.returncode != 0:
        print(f"  ERROR getting message: {result.stderr[:200]}")
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"  ERROR parsing JSON: {result.stdout[:200]}")
        return None

def download_attachment(msg_id, att_id, out_path):
    env = {**os.environ, "GOG_KEYRING_PASSWORD": GOG_PASSWORD}
    result = subprocess.run(
        ["gog", "gmail", "attachment", msg_id, att_id,
         "--account", GOG_ACCOUNT, "--out", out_path, "--no-input"],
        capture_output=True, text=True, env=env, timeout=120
    )
    return result.returncode == 0 or os.path.exists(out_path)

def main():
    if not GOG_ACCOUNT:
        print("ERROR: GOG_ACCOUNT is not set. Example: export GOG_ACCOUNT='you@example.com'")
        sys.exit(1)
    if not GOG_PASSWORD:
        print("ERROR: GOG_KEYRING_PASSWORD is not set.")
        print("Example: export GOG_KEYRING_PASSWORD='...'")
        sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)

    manifest = []
    stats = {"total": 0, "pdfs": 0, "excels": 0, "errors": 0}
    
    for msg_id, subject in MESSAGES:
        print(f"\n[{msg_id}] {subject}")
        
        msg = get_message(msg_id)
        if not msg:
            stats["errors"] += 1
            continue
        
        attachments = msg.get("attachments", [])
        if not attachments:
            print(f"  WARNING: No attachments")
            continue
        
        entry = {
            "message_id": msg_id,
            "subject": f"Fwd: {subject}",
            "attachments": []
        }
        
        for att in attachments:
            filename = att.get("filename", "unknown")
            att_id = att.get("attachmentId", "")
            mime = att.get("mimeType", "")
            
            if not att_id:
                print(f"  SKIP (no ID): {filename}")
                continue
            
            out_path = os.path.join(OUT_DIR, filename)
            
            # Skip if already downloaded
            if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                print(f"  CACHED: {filename}")
                entry["attachments"].append({
                    "filename": filename,
                    "path": out_path,
                    "mime": mime,
                    "size": att.get("size", 0),
                    "status": "cached"
                })
                if filename.endswith(".pdf"):
                    stats["pdfs"] += 1
                elif filename.endswith(".xlsx"):
                    stats["excels"] += 1
                continue
            
            print(f"  Downloading: {filename} ({att.get('sizeHuman', '?')})")
            ok = download_attachment(msg_id, att_id, out_path)
            
            if ok:
                print(f"  OK: {filename}")
                entry["attachments"].append({
                    "filename": filename,
                    "path": out_path,
                    "mime": mime,
                    "size": att.get("size", 0),
                    "status": "downloaded"
                })
                if filename.endswith(".pdf"):
                    stats["pdfs"] += 1
                elif filename.endswith(".xlsx"):
                    stats["excels"] += 1
                stats["total"] += 1
            else:
                print(f"  FAIL: {filename}")
                stats["errors"] += 1
                entry["attachments"].append({
                    "filename": filename,
                    "status": "error"
                })
        
        manifest.append(entry)
    
    # Save manifest
    with open(MANIFEST_PATH, "w") as f:
        json.dump(manifest, f, indent=2)
    
    print(f"\n{'='*60}")
    print(f"Download complete!")
    print(f"  Messages processed: {len(MESSAGES)}")
    print(f"  PDFs downloaded: {stats['pdfs']}")
    print(f"  Excel files downloaded: {stats['excels']}")
    print(f"  New downloads: {stats['total']}")
    print(f"  Errors: {stats['errors']}")
    print(f"  Manifest: {MANIFEST_PATH}")
    print(f"  Files: {OUT_DIR}")

if __name__ == "__main__":
    main()
