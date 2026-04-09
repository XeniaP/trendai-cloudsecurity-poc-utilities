#!/usr/bin/env bash
# =============================================================================
# Azure Storage Security Detection Performance Test
# Uploads various file types, sizes, and EICAR test files to a Blob container
# to evaluate malware detection latency and coverage.
#
# Requirements: az cli (pre-installed in Azure Cloud Shell)
#
# Usage:
#   chmod +x Performance_Test.sh
#   ./Performance_Test.sh -a <storage_account> -c <container> [OPTIONS]
#
# Options:
#   -a  Storage account name                    (required)
#   -c  Container name                          (required)
#   -s  Subscription ID                         (optional)
#   -o  Output CSV file                         (default: detection_perf_results.csv)
#   -t  Max parallel uploads                    (default: 4)
#   -n  Number of random-sized files            (default: 5)
#   -L  Min size in MB for random files         (default: 5)
#   -H  Max size in MB for random files         (default: 3072)
#   -S  Skip fixed clean files >= 50 MB
#   -d  Dry-run: list files only, no upload
#   -h  Show this help
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
STORAGE_ACCOUNT=""
CONTAINER=""
SUBSCRIPTION=""
OUTPUT_CSV="detection_perf_results.csv"
MAX_JOBS=40
RAND_FILE_COUNT=5
RAND_MIN_MB=5
RAND_MAX_MB=3072
SKIP_LARGE=false
DRY_RUN=false
WORK_DIR="./Files"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[FAIL]${NC}  $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while getopts ":a:c:s:o:t:n:L:H:Sdh" opt; do
  case $opt in
    a) STORAGE_ACCOUNT="$OPTARG" ;;
    c) CONTAINER="$OPTARG"       ;;
    s) SUBSCRIPTION="$OPTARG"    ;;
    o) OUTPUT_CSV="$OPTARG"      ;;
    t) MAX_JOBS="$OPTARG"        ;;
    n) RAND_FILE_COUNT="$OPTARG" ;;
    L) RAND_MIN_MB="$OPTARG"     ;;
    H) RAND_MAX_MB="$OPTARG"     ;;
    S) SKIP_LARGE=true           ;;
    d) DRY_RUN=true              ;;
    h) sed -n '/^# Usage/,/^# ===/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    :) echo "Option -$OPTARG requires an argument."; exit 1 ;;
   \?) echo "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

[[ -z "$STORAGE_ACCOUNT" ]] && { echo "ERROR: -a <storage_account> is required."; exit 1; }
[[ -z "$CONTAINER" ]]       && { echo "ERROR: -c <container> is required."; exit 1; }
[[ "$RAND_FILE_COUNT" =~ ^[0-9]+$ ]] || { echo "ERROR: -n must be a non-negative integer."; exit 1; }
[[ "$RAND_MIN_MB"     =~ ^[0-9]+$ ]] || { echo "ERROR: -L must be a positive integer (MB)."; exit 1; }
[[ "$RAND_MAX_MB"     =~ ^[0-9]+$ ]] || { echo "ERROR: -H must be a positive integer (MB)."; exit 1; }
(( RAND_MIN_MB < RAND_MAX_MB )) || { echo "ERROR: -L (${RAND_MIN_MB}) must be less than -H (${RAND_MAX_MB})."; exit 1; }

# ---------------------------------------------------------------------------
# Working directory for generated files (set in Defaults above)
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# File catalogue arrays
# ---------------------------------------------------------------------------
FILE_PATHS=()
FILE_BLOBS=()
FILE_CATS=()
FILE_EXPECTED=()

add_file() {
  FILE_PATHS+=("$1")
  FILE_BLOBS+=("$2")
  FILE_CATS+=("$3")
  FILE_EXPECTED+=("$4")
}

# ---------------------------------------------------------------------------
# File generators
# ---------------------------------------------------------------------------

# Write exactly $size bytes of /dev/urandom into $path (fast: 1 MB blocks)
gen_binary() {
  local path="$1" size="$2"
  local bs=1048576
  local blocks=$(( size / bs ))
  local rem=$(( size % bs ))
  {
    if (( blocks > 0 )); then
      dd if=/dev/urandom bs=$bs count=$blocks 2>/dev/null
    fi
    if (( rem > 0 )); then
      dd if=/dev/urandom bs=$rem count=1 2>/dev/null
    fi
  } > "$path"
}

# Write exactly $size bytes of printable text into $path
gen_text() {
  local path="$1" size="$2"
  # Generate more than needed (tr shrinks ~75%), then truncate
  local needed=$(( size * 5 ))
  local bs=1048576
  local blocks=$(( needed / bs + 1 ))
  dd if=/dev/urandom bs=$bs count=$blocks 2>/dev/null \
    | LC_ALL=C tr -dc 'A-Za-z0-9 \n' \
    | dd bs=$size count=1 2>/dev/null \
    > "$path" || true
  # Pad with spaces if still short
  local actual
  actual=$(wc -c < "$path")
  if (( actual < size )); then
    dd if=/dev/zero bs=1 count=$(( size - actual )) 2>/dev/null >> "$path"
  fi
}

# Write a file with a magic-byte header + random payload of total $size bytes
gen_with_header() {
  local path="$1" size="$2" header="$3"  # header is a hex string like "FFD8FFE0"
  local hlen=$(( ${#header} / 2 ))
  printf '%b' "$(echo "$header" | sed 's/../\\x&/g')" > "$path"
  local rem=$(( size - hlen ))
  if (( rem > 0 )); then
    dd if=/dev/urandom bs=$rem count=1 2>/dev/null >> "$path"
  fi
}

# Create a ZIP containing one file — uses Python so no 'zip' binary needed (works on Windows)
make_zip() {
  local zip_path="$1" inner_name="$2" inner_data_path="$3"
  python3 - "$zip_path" "$inner_name" "$inner_data_path" <<'PYEOF'
import sys, zipfile, os
zip_path, inner_name, src = sys.argv[1], sys.argv[2], sys.argv[3]
# Resolve absolute path before chdir
zip_path = os.path.abspath(zip_path)
src      = os.path.abspath(src)
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(src, inner_name)
PYEOF
}

# EICAR standard anti-malware test string (safe, not a real virus)
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'

# ---------------------------------------------------------------------------
# Random size: returns byte count uniformly in [MIN_MB, MAX_MB)
# Uses /dev/urandom — avoids $RANDOM's 32 KB ceiling
# ---------------------------------------------------------------------------
rand_bytes() {
  local min=$(( RAND_MIN_MB * 1048576 ))
  local max=$(( RAND_MAX_MB * 1048576 ))
  local range=$(( max - min ))
  local r
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
  echo $(( min + r % range ))
}

# ---------------------------------------------------------------------------
# Build the test catalogue
# ---------------------------------------------------------------------------
build_catalogue() {
  info "Generating test files in $WORK_DIR …"
  local f tmp

  # --- EICAR variants --------------------------------------------------------
  f="$WORK_DIR/eicar_plain.txt"
  printf '%s' "$EICAR" > "$f"
  add_file "$f" "eicar/eicar_plain.txt" "EICAR" "MALWARE_DETECTED"

  f="$WORK_DIR/eicar_renamed.jpg"
  printf '%s' "$EICAR" > "$f"
  add_file "$f" "eicar/eicar_renamed.jpg" "EICAR_RENAMED" "MALWARE_DETECTED"

  f="$WORK_DIR/eicar_zipped.zip"
  tmp="$WORK_DIR/_eicar.txt"; printf '%s' "$EICAR" > "$tmp"
  make_zip "$f" "eicar.txt" "$tmp"
  add_file "$f" "eicar/eicar_zipped.zip" "EICAR_ZIP" "MALWARE_DETECTED"

  f="$WORK_DIR/eicar_double.zip"
  local inner_zip="$WORK_DIR/_eicar_inner.zip"
  make_zip "$inner_zip" "eicar.txt" "$WORK_DIR/_eicar.txt"
  make_zip "$f" "inner.zip" "$inner_zip"
  add_file "$f" "eicar/eicar_double_zipped.zip" "EICAR_DOUBLE_ZIP" "MALWARE_DETECTED"

  f="$WORK_DIR/eicar_in_docx.docx"
  make_zip "$f" "word/document.xml" "$WORK_DIR/_eicar.txt"
  add_file "$f" "eicar/eicar_in_docx.docx" "EICAR_DOCX" "MALWARE_DETECTED"

  # --- Clean files – fixed sizes ---------------------------------------------
  local -A sizes=( [1KB]=1024 [100KB]=102400 [1MB]=1048576 [10MB]=10485760 )
  if [[ "$SKIP_LARGE" == false ]]; then
    sizes[50MB]=52428800
    sizes[100MB]=104857600
  fi

  for label in 1KB 100KB 1MB 10MB 50MB 100MB; do
    [[ -z "${sizes[$label]+_}" ]] && continue
    local sz="${sizes[$label]}"

    f="$WORK_DIR/text_${label}.txt"
    gen_text "$f" "$sz"
    add_file "$f" "clean/text_${label}.txt" "CLEAN_TXT_${label}" "CLEAN"

    f="$WORK_DIR/binary_${label}.bin"
    gen_binary "$f" "$sz"
    add_file "$f" "clean/binary_${label}.bin" "CLEAN_BIN_${label}" "CLEAN"
  done

  # --- Clean files – various extensions --------------------------------------
  f="$WORK_DIR/script.ps1";  gen_text   "$f" 4096;   add_file "$f" "filetypes/script.ps1"     "CLEAN_PS1"   "CLEAN"
  f="$WORK_DIR/script.sh";   gen_text   "$f" 4096;   add_file "$f" "filetypes/script.sh"      "CLEAN_SH"    "CLEAN"
  f="$WORK_DIR/data.csv";    gen_text   "$f" 20480;  add_file "$f" "filetypes/data.csv"       "CLEAN_CSV"   "CLEAN"
  f="$WORK_DIR/data.json";   gen_text   "$f" 4096;   add_file "$f" "filetypes/config.json"    "CLEAN_JSON"  "CLEAN"
  f="$WORK_DIR/backup.dat";  gen_binary "$f" 204800; add_file "$f" "filetypes/backup.tar.gz"  "CLEAN_TARGZ" "CLEAN"

  # PDF stub: %PDF-1.4 header + random payload
  f="$WORK_DIR/document.pdf"
  { printf '%%PDF-1.4\n%%\xe2\xe3\xcf\xd3\n'; dd if=/dev/urandom bs=51100 count=1 2>/dev/null; } > "$f"
  add_file "$f" "filetypes/document.pdf" "CLEAN_PDF" "CLEAN"

  # DOCX stub: minimal ZIP with word/document.xml
  f="$WORK_DIR/document.docx"
  tmp="$WORK_DIR/_docx_content.xml"
  gen_text "$tmp" 40960
  make_zip "$f" "word/document.xml" "$tmp"
  add_file "$f" "filetypes/document.docx" "CLEAN_DOCX" "CLEAN"

  # Image stubs with correct magic bytes
  f="$WORK_DIR/image.jpg";  gen_with_header "$f" 51200 "FFD8FFE0"
  add_file "$f" "filetypes/image.jpg" "CLEAN_JPG" "CLEAN"

  f="$WORK_DIR/image.png";  gen_with_header "$f" 51200 "89504E47"
  add_file "$f" "filetypes/image.png" "CLEAN_PNG" "CLEAN"

  # EXE stub: MZ header + random payload (no real code — purely for extension/header testing)
  f="$WORK_DIR/executable.exe"; gen_with_header "$f" 10240 "4D5A"
  add_file "$f" "filetypes/executable.exe" "CLEAN_EXE" "CLEAN"

  # Clean ZIP
  f="$WORK_DIR/archive.zip"
  tmp="$WORK_DIR/_archive_inner.bin"; gen_binary "$tmp" 10240
  make_zip "$f" "data.bin" "$tmp"
  add_file "$f" "filetypes/archive.zip" "CLEAN_ZIP" "CLEAN"

  # --- Random-sized files ----------------------------------------------------
  if (( RAND_FILE_COUNT > 0 )); then
    info "Generating $RAND_FILE_COUNT random files (${RAND_MIN_MB} MB – ${RAND_MAX_MB} MB each) …"
    local rand_exts=( bin dat log txt pdf )
    local i sz size_mb ext
    for (( i = 1; i <= RAND_FILE_COUNT; i++ )); do
      sz=$(rand_bytes)
      size_mb=$(awk "BEGIN{printf \"%.0f\", $sz/1048576}")
      ext="${rand_exts[$(( RANDOM % ${#rand_exts[@]} ))]}"
      f="$WORK_DIR/randsize_${i}.${ext}"
      gen_binary "$f" "$sz"
      add_file "$f" "random/randfile_${i}_${size_mb}MB.${ext}" "RAND_${size_mb}MB" "CLEAN"
      info "  file $i/$RAND_FILE_COUNT: ${size_mb} MB (.${ext})"
    done
  fi

  ok "Catalogue ready: ${#FILE_PATHS[@]} files."
}

# ---------------------------------------------------------------------------
# Azure helpers
# ---------------------------------------------------------------------------
ensure_container() {
  info "Checking container '$CONTAINER' …"
  local exists
  exists=$(az storage container exists \
    --name "$CONTAINER" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} \
    --query "exists" -o tsv 2>/dev/null || echo "false")
  if [[ "$exists" == "true" ]]; then
    info "Container exists – reusing."
  else
    az storage container create \
      --name "$CONTAINER" \
      --account-name "$STORAGE_ACCOUNT" \
      --auth-mode login \
      ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} \
      --output none
    ok "Container '$CONTAINER' created."
  fi
}

# ---------------------------------------------------------------------------
# Upload worker (runs in background subshell)
# ---------------------------------------------------------------------------
LOCK_FILE=""
COUNTER_FILE=""
TOTAL=0

upload_one() {
  local idx="$1"
  local local_path="${FILE_PATHS[$idx]}"
  local blob_name="${FILE_BLOBS[$idx]}"
  local category="${FILE_CATS[$idx]}"
  local expected="${FILE_EXPECTED[$idx]}"
  local size
  size=$(wc -c < "$local_path" 2>/dev/null || echo 0)

  # Atomic counter increment (mkdir-based lock — works on Windows Git Bash)
  local seq
  while ! mkdir "${LOCK_FILE}.d" 2>/dev/null; do sleep 0.05; done
  seq=$(( $(cat "$COUNTER_FILE") + 1 ))
  echo "$seq" > "$COUNTER_FILE"
  rmdir "${LOCK_FILE}.d"

  local ts start_ms end_ms elapsed_ms status az_out error_msg=""

  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

  if az_out=$(az storage blob upload \
      --container-name "$CONTAINER" \
      --name            "$blob_name" \
      --file            "$local_path" \
      --overwrite       true \
      --account-name    "$STORAGE_ACCOUNT" \
      --auth-mode       login \
      ${SUBSCRIPTION:+--subscription "$SUBSCRIPTION"} \
      --output none 2>&1); then
    status="OK"
  else
    status="FAIL"
    error_msg=$(echo "$az_out" | tr '",\n' "   " | xargs)
  fi

  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  elapsed_ms=$(( end_ms - start_ms ))

  # Human-readable size
  local size_label
  if   (( size >= 1073741824 )); then size_label="$(awk "BEGIN{printf \"%.1f GB\", $size/1073741824}")"
  elif (( size >= 1048576 ));    then size_label="$(awk "BEGIN{printf \"%.1f MB\", $size/1048576}")"
  elif (( size >= 1024 ));       then size_label="$(awk "BEGIN{printf \"%.1f KB\", $size/1024}")"
  else                                size_label="${size} B"
  fi

  local tag
  if [[ "$status" == "OK" ]]; then
    tag="${GREEN}[ OK ]${NC}"
  else
    tag="${RED}[FAIL]${NC}"
  fi
  echo -e "${tag} [$(printf '%3d' "$seq")/$TOTAL] ${elapsed_ms}ms  $(printf '%9s' "$size_label")  $blob_name${error_msg:+  ↳ $error_msg}"

  # Write CSV row (mkdir-based lock)
  while ! mkdir "${LOCK_FILE}.d" 2>/dev/null; do sleep 0.05; done
  printf '"%s","%s","%s","%s",%d,"%s",%d,"%s"\n' \
    "$ts" "$blob_name" "$category" "$expected" \
    "$size" "$status" "$elapsed_ms" "$error_msg" \
    >> "$OUTPUT_CSV"
  rmdir "${LOCK_FILE}.d"
}

# ---------------------------------------------------------------------------
# Parallel upload runner
# ---------------------------------------------------------------------------
run_uploads() {
  TOTAL="${#FILE_PATHS[@]}"
  LOCK_FILE="$WORK_DIR/.lock"
  COUNTER_FILE="$WORK_DIR/.counter"
  rmdir "${LOCK_FILE}.d" 2>/dev/null || true   # clean up any stale lock
  echo 0 > "$COUNTER_FILE"

  printf 'timestamp,blob_name,category,expected,size_bytes,status,upload_ms,error\n' > "$OUTPUT_CSV"

  bold "\nUploading $TOTAL files to '$CONTAINER' (max $MAX_JOBS parallel) …\n"

  local pids=() pid running
  for i in "${!FILE_PATHS[@]}"; do
    upload_one "$i" &
    pids+=($!)

    # Throttle: wait until pool has room
    while (( ${#pids[@]} >= MAX_JOBS )); do
      running=()
      for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && running+=("$pid")
      done
      pids=("${running[@]}")
      (( ${#pids[@]} >= MAX_JOBS )) && sleep 0.3
    done
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local total ok_count fail
  total=$(( $(wc -l < "$OUTPUT_CSV") - 1 ))
  ok_count=$(grep -c '"OK"' "$OUTPUT_CSV" 2>/dev/null || echo 0)
  fail=$(( total - ok_count ))

  local min_ms avg_ms max_ms
  min_ms=$(awk -F',' 'NR>1 {print $7}' "$OUTPUT_CSV" | sort -n | head -1)
  max_ms=$(awk -F',' 'NR>1 {print $7}' "$OUTPUT_CSV" | sort -n | tail -1)
  avg_ms=$(awk -F',' 'NR>1 {sum+=$7; n++} END {if(n>0) printf "%.0f", sum/n; else print 0}' "$OUTPUT_CSV")

  echo
  bold "============================================================"
  bold " UPLOAD SUMMARY"
  bold "============================================================"
  echo -e "  Total files  : ${BOLD}${total}${NC}"
  echo -e "  Succeeded    : ${GREEN}${ok_count}${NC}"
  echo -e "  Failed       : ${RED}${fail}${NC}"
  echo -e "  Upload time  : min=${min_ms}ms  avg=${avg_ms}ms  max=${max_ms}ms"
  bold "============================================================"
  echo -e "  Results: ${CYAN}${OUTPUT_CSV}${NC}"

  if (( fail > 0 )); then
    echo
    warn "Failed uploads:"
    awk -F',' 'NR>1 && $6!="\"OK\"" {gsub(/"/, "", $2); gsub(/"/, "", $8); print "  " $2 " → " $8}' "$OUTPUT_CSV"
  fi
}

# ---------------------------------------------------------------------------
# Dry-run listing
# ---------------------------------------------------------------------------
dry_run_list() {
  printf "%-28s %-20s %10s  %s\n" "CATEGORY" "EXPECTED" "SIZE" "BLOB"
  printf '%.0s-' {1..80}; echo
  local i sz label
  for i in "${!FILE_PATHS[@]}"; do
    sz=$(wc -c < "${FILE_PATHS[$i]}" 2>/dev/null || echo 0)
    if   (( sz >= 1073741824 )); then label="$(awk "BEGIN{printf \"%.1f GB\", $sz/1073741824}")"
    elif (( sz >= 1048576 ));    then label="$(awk "BEGIN{printf \"%.1f MB\", $sz/1048576}")"
    elif (( sz >= 1024 ));       then label="$(awk "BEGIN{printf \"%.1f KB\", $sz/1024}")"
    else                              label="${sz} B"
    fi
    printf "%-28s %-20s %10s  %s\n" \
      "${FILE_CATS[$i]}" "${FILE_EXPECTED[$i]}" "$label" "${FILE_BLOBS[$i]}"
  done
  echo
  echo "Total: ${#FILE_PATHS[@]} files"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo
  bold "Azure Storage Security Detection Performance Test"
  bold "================================================="
  info "Storage Account : $STORAGE_ACCOUNT"
  info "Container       : $CONTAINER"
  info "Output CSV      : $OUTPUT_CSV"
  info "Parallel jobs   : $MAX_JOBS"
  info "Random files    : $RAND_FILE_COUNT  (${RAND_MIN_MB} MB – ${RAND_MAX_MB} MB each)"
  info "Skip large fixed: $SKIP_LARGE"
  echo

  command -v az &>/dev/null || { echo "ERROR: 'az' not found. Run from Azure Cloud Shell."; exit 1; }
  az account show &>/dev/null || { err "Not logged in. Run 'az login'."; exit 1; }

  build_catalogue

  if [[ "$DRY_RUN" == true ]]; then
    dry_run_list
    return
  fi

  ensure_container
  run_uploads
  print_summary
}

main
