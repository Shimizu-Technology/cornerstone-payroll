#!/bin/bash
# Download all MoSa payroll attachments from Gmail
# Output: ~/work/cornerstone-payroll/data/mosa-2025/raw/

set -e
export GOG_KEYRING_PASSWORD=clawdbot
ACCOUNT="jerry.shimizutechnology@gmail.com"
OUT_DIR="$HOME/work/cornerstone-payroll/data/mosa-2025/raw"
MANIFEST="$OUT_DIR/../manifest.json"

mkdir -p "$OUT_DIR"

# All Fwd: payroll message IDs
MSG_IDS=(
  "19ccfcf3422947b6"  # Fwd: Payroll 12/15-12/27
  "19ccfcf1c901c17a"  # Fwd: Payroll 12/1-12/13
  "19ccfcf07bf6f086"  # Fwd: payroll 11/17-11/29
  "19ccfcf002d65ecf"  # Fwd: Payroll 11/3-11/15
  "19ccfcee57be6169"  # Fwd: Payroll 10/20-11/2
  "19ccfcebc21e6d9d"  # Fwd: Mosa's Payroll 9/22-10/4
  "19ccfceaefef098e"  # Fwd: Payroll 9/8-9/20
  "19ccfcea50ca5563"  # Fwd: Payroll 8/25-9/6
  "19ccfce5dbfd847a"  # Fwd: Payroll 8/11-8/23
  "19ccfce528b4a7c5"  # Fwd: Payroll 7/28-8/9
  "19ccfce1f40592d6"  # Fwd: Payroll 6/30-7/12
  "19ccfce1bf44e30e"  # Fwd: Payroll 7/14-7/26
  "19ccfcdf2a97524e"  # Fwd: Payroll 6/16 to 6/28
  "19ccfcdecd024748"  # Fwd: Payroll 6/2-6/15
  "19ccfcdd353d7067"  # Fwd: Payroll 5/19-5/31
  "19ccfcdadd31bf74"  # Fwd: Payroll 5/5-5/17
  "19ccfcd98e0af9e3"  # Fwd: Payroll 4/21-5/3
  "19ccfcd81c55e151"  # Fwd: Payroll 4/7-4/19
  "19ccfcd80de79348"  # Fwd: Payroll 3/24-4/5
  "19ccfcd65c8b5563"  # Fwd: Payroll 3/10-3/22
  "19ccfcd4431c018a"  # Fwd: Payroll 2/23-3/8
  "19ccfcd2f8c9544f"  # Fwd: Payroll 2/10-2/22
  "19ccfcd18c3f11db"  # Fwd: Payroll 1/27-2/8
  "19ccfcd024d8acc2"  # Fwd: Payroll 1/13-1/25
  "19ccfccadf93a4fe"  # Fwd: Payroll 12/30-1/11 (PP1 2025)
  "19ccfcc91ed7a3fc"  # Fwd: Payroll 12/16-12/29 (last 2024 period)
  "19ccfcc8555945ff"  # Fwd: Payroll 1/12-1/24
)

echo "Downloading attachments for ${#MSG_IDS[@]} messages..."
echo "[]" > "$MANIFEST"

for MSG_ID in "${MSG_IDS[@]}"; do
  echo ""
  echo "Processing message: $MSG_ID"
  
  # Get message details
  MSG_JSON=$(gog gmail get "$MSG_ID" --account "$ACCOUNT" --json 2>&1)
  
  # Extract attachment info
  python3 - "$MSG_ID" "$OUT_DIR" "$MANIFEST" <<'PYEOF'
import json, sys, os, subprocess

msg_id = sys.argv[1]
out_dir = sys.argv[2]
manifest_path = sys.argv[3]

msg_json = sys.stdin.read()
try:
    data = json.loads(msg_json)
except:
    print(f"  ERROR: Could not parse JSON for {msg_id}")
    sys.exit(0)

attachments = data.get('attachments', [])
body = data.get('body', '')

if not attachments:
    print(f"  No attachments found")
    sys.exit(0)

# Load manifest
with open(manifest_path) as f:
    manifest = json.load(f)

entry = {'message_id': msg_id, 'attachments': []}

for att in attachments:
    filename = att.get('filename', 'unknown')
    att_id = att.get('attachmentId', '')
    if not att_id:
        print(f"  SKIP (no attachmentId): {filename}")
        continue
    
    out_path = os.path.join(out_dir, filename)
    print(f"  Downloading: {filename} ({att.get('sizeHuman', '?')})")
    
    result = subprocess.run([
        'gog', 'gmail', 'attachment', msg_id, att_id,
        '--account', 'jerry.shimizutechnology@gmail.com',
        '--out', out_path
    ], capture_output=True, text=True, 
       env={**__import__('os').environ, 'GOG_KEYRING_PASSWORD': 'clawdbot'})
    
    if result.returncode == 0 or os.path.exists(out_path):
        print(f"  OK: {out_path}")
        entry['attachments'].append({
            'filename': filename,
            'path': out_path,
            'mime': att.get('mimeType', ''),
            'size': att.get('size', 0)
        })
    else:
        print(f"  FAIL: {result.stderr[:200]}")

manifest.append(entry)
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)
PYEOF
  
done << "$MSG_JSON"
done

echo ""
echo "Done! Files saved to: $OUT_DIR"
ls -la "$OUT_DIR"
