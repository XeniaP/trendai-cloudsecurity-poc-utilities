#!/usr/bin/env python3
"""
Azure Storage Security Detection Performance Test
Uploads various file types, sizes, and EICAR malware test strings
to a specified Azure Blob Storage container to evaluate detection latency.

Usage (Azure Cloud Shell):
    python Performance_Test.py \
        --account-name <storage_account> \
        --container <container_name> \
        [--account-key <key> | --sas-token <token>]  # omit to use managed identity
        [--threads 4]
        [--output results.csv]
"""

import argparse
import csv
import io
import random
import string
import sys
import threading
import time
import zipfile
from datetime import datetime, timezone
from typing import Optional

# ---------------------------------------------------------------------------
# Dependency check – azure-storage-blob is pre-installed in Cloud Shell
# ---------------------------------------------------------------------------
try:
    from azure.storage.blob import BlobServiceClient
    from azure.identity import DefaultAzureCredential
except ImportError:
    sys.exit(
        "Required packages missing. Run:\n"
        "  pip install azure-storage-blob azure-identity"
    )

# ---------------------------------------------------------------------------
# EICAR standard anti-malware test string (safe, not a real virus)
# ---------------------------------------------------------------------------
EICAR_STRING = (
    r"X5O!P%@AP[4\PZX54(P^)7CC)7}"
    r"$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
)

# ---------------------------------------------------------------------------
# File generators
# ---------------------------------------------------------------------------

def _random_text(size_bytes: int) -> bytes:
    """Generate random printable text of exactly size_bytes."""
    chunk = (string.ascii_letters + string.digits + " \n").encode()
    data = (chunk * (size_bytes // len(chunk) + 1))[:size_bytes]
    return data


def _random_binary(size_bytes: int) -> bytes:
    """Generate random binary data."""
    return bytes(random.getrandbits(8) for _ in range(size_bytes))


def _make_zip(inner_name: str, inner_bytes: bytes) -> bytes:
    """Wrap bytes inside a ZIP archive."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(inner_name, inner_bytes)
    return buf.getvalue()


def _make_pdf_shell(size_bytes: int) -> bytes:
    """
    Minimal syntactically-plausible PDF with padding to reach size_bytes.
    (Not a valid rendered PDF – purely for upload/extension testing.)
    """
    header = b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n"
    padding = b"%" + _random_text(max(0, size_bytes - len(header)))
    return (header + padding)[:size_bytes]


def _make_docx_shell(size_bytes: int) -> bytes:
    """Minimal DOCX-like ZIP with a word/document.xml stub."""
    content = b"<w:document><w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>"
    padding = _random_text(max(0, size_bytes - len(content)))
    return _make_zip("word/document.xml", content + padding)


# ---------------------------------------------------------------------------
# Test-case catalogue
# ---------------------------------------------------------------------------

def build_test_cases() -> list[dict]:
    """
    Return a list of dicts, each describing one upload:
        name      – blob name in the container
        data      – bytes to upload
        category  – label for reporting
        expected  – 'MALWARE_DETECTED' | 'CLEAN'
    """
    cases = []

    # --- EICAR variants -------------------------------------------------------
    eicar_bytes = EICAR_STRING.encode("ascii")

    cases.append(dict(
        name="eicar/eicar_plain.txt",
        data=eicar_bytes,
        category="EICAR",
        expected="MALWARE_DETECTED",
    ))
    cases.append(dict(
        name="eicar/eicar_renamed.jpg",
        data=eicar_bytes,
        category="EICAR",
        expected="MALWARE_DETECTED",
    ))
    cases.append(dict(
        name="eicar/eicar_zipped.zip",
        data=_make_zip("eicar.txt", eicar_bytes),
        category="EICAR_ZIP",
        expected="MALWARE_DETECTED",
    ))
    cases.append(dict(
        name="eicar/eicar_double_zipped.zip",
        data=_make_zip("inner.zip", _make_zip("eicar.txt", eicar_bytes)),
        category="EICAR_DOUBLE_ZIP",
        expected="MALWARE_DETECTED",
    ))
    cases.append(dict(
        name="eicar/eicar_in_docx.docx",
        data=_make_zip("word/document.xml", eicar_bytes),
        category="EICAR_DOCX",
        expected="MALWARE_DETECTED",
    ))

    # --- Clean files – various sizes ------------------------------------------
    sizes = {
        "1KB":   1 * 1024,
        "100KB": 100 * 1024,
        "1MB":   1 * 1024 * 1024,
        "10MB":  10 * 1024 * 1024,
        "50MB":  50 * 1024 * 1024,
        "100MB": 100 * 1024 * 1024,
    }

    for label, sz in sizes.items():
        cases.append(dict(
            name=f"clean/text_{label}.txt",
            data=_random_text(sz),
            category=f"CLEAN_TXT_{label}",
            expected="CLEAN",
        ))
        cases.append(dict(
            name=f"clean/binary_{label}.bin",
            data=_random_binary(sz),
            category=f"CLEAN_BIN_{label}",
            expected="CLEAN",
        ))

    # --- Clean files – various extensions -------------------------------------
    ext_samples = [
        ("script.ps1",  _random_text(4 * 1024)),
        ("script.sh",   _random_text(4 * 1024)),
        ("archive.zip", _make_zip("data.bin", _random_binary(10 * 1024))),
        ("document.pdf",_make_pdf_shell(50 * 1024)),
        ("document.docx", _make_docx_shell(50 * 1024)),
        ("image.jpg",   bytes([0xFF, 0xD8, 0xFF, 0xE0]) + _random_binary(50 * 1024)),
        ("image.png",   bytes([0x89, 0x50, 0x4E, 0x47]) + _random_binary(50 * 1024)),
        ("data.csv",    _random_text(20 * 1024)),
        ("config.json", b'{"test": true, "data": "' + _random_text(1024) + b'"}'),
        ("backup.tar.gz", _random_binary(200 * 1024)),
        ("executable.exe", bytes([0x4D, 0x5A]) + _random_binary(10 * 1024)),  # MZ header (clean random)
    ]
    for fname, data in ext_samples:
        cases.append(dict(
            name=f"filetypes/{fname}",
            data=data,
            category=f"CLEAN_{fname.split('.')[-1].upper()}",
            expected="CLEAN",
        ))

    return cases


# ---------------------------------------------------------------------------
# Upload logic
# ---------------------------------------------------------------------------

class UploadResult:
    def __init__(self, name: str, category: str, expected: str,
                 size_bytes: int, success: bool,
                 upload_ms: float, error: Optional[str] = None):
        self.name = name
        self.category = category
        self.expected = expected
        self.size_bytes = size_bytes
        self.success = success
        self.upload_ms = upload_ms
        self.error = error
        self.timestamp = datetime.now(timezone.utc).isoformat()


def upload_blob(container_client, case: dict) -> UploadResult:
    size = len(case["data"])
    start = time.perf_counter()
    error = None
    success = False
    try:
        blob_client = container_client.get_blob_client(case["name"])
        blob_client.upload_blob(
            io.BytesIO(case["data"]),
            overwrite=True,
            length=size,
        )
        success = True
    except Exception as exc:
        error = str(exc)
    elapsed_ms = (time.perf_counter() - start) * 1000

    return UploadResult(
        name=case["name"],
        category=case["category"],
        expected=case["expected"],
        size_bytes=size,
        success=success,
        upload_ms=elapsed_ms,
        error=error,
    )


# ---------------------------------------------------------------------------
# CLI & orchestration
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Azure Storage Security Detection Performance Test",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--account-name", required=True,
                        help="Azure Storage account name")
    parser.add_argument("--container", required=True,
                        help="Target blob container name")
    parser.add_argument("--account-key", default=None,
                        help="Storage account key (omit to use Managed Identity / az login)")
    parser.add_argument("--sas-token", default=None,
                        help="SAS token (alternative to --account-key)")
    parser.add_argument("--threads", type=int, default=4,
                        help="Parallel upload threads (default: 4)")
    parser.add_argument("--output", default="detection_perf_results.csv",
                        help="CSV output file (default: detection_perf_results.csv)")
    parser.add_argument("--dry-run", action="store_true",
                        help="List test cases without uploading")
    parser.add_argument("--skip-large", action="store_true",
                        help="Skip files >= 50 MB (useful for quick smoke tests)")
    return parser.parse_args()


def get_service_client(args) -> BlobServiceClient:
    account_url = f"https://{args.account_name}.blob.core.windows.net"
    if args.account_key:
        return BlobServiceClient(account_url=account_url, credential=args.account_key)
    if args.sas_token:
        token = args.sas_token if args.sas_token.startswith("?") else "?" + args.sas_token
        return BlobServiceClient(account_url=account_url + token)
    # Fall back to DefaultAzureCredential (Managed Identity in Cloud Shell)
    return BlobServiceClient(account_url=account_url,
                             credential=DefaultAzureCredential())


def print_summary(results: list[UploadResult]):
    total = len(results)
    ok = sum(1 for r in results if r.success)
    failed = total - ok
    times = [r.upload_ms for r in results if r.success]
    avg_ms = sum(times) / len(times) if times else 0
    max_ms = max(times) if times else 0
    min_ms = min(times) if times else 0

    print("\n" + "=" * 60)
    print("UPLOAD SUMMARY")
    print("=" * 60)
    print(f"  Total files  : {total}")
    print(f"  Succeeded    : {ok}")
    print(f"  Failed       : {failed}")
    print(f"  Upload time  : min={min_ms:.0f}ms  avg={avg_ms:.0f}ms  max={max_ms:.0f}ms")
    print("=" * 60)

    if failed:
        print("\nFailed uploads:")
        for r in results:
            if not r.success:
                print(f"  [{r.name}] {r.error}")


def save_csv(results: list[UploadResult], path: str):
    fields = ["timestamp", "name", "category", "expected", "size_bytes",
              "success", "upload_ms", "error"]
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for r in results:
            writer.writerow({
                "timestamp": r.timestamp,
                "name": r.name,
                "category": r.category,
                "expected": r.expected,
                "size_bytes": r.size_bytes,
                "success": r.success,
                "upload_ms": f"{r.upload_ms:.2f}",
                "error": r.error or "",
            })
    print(f"\nResults saved to: {path}")


def main():
    args = parse_args()
    cases = build_test_cases()

    if args.skip_large:
        cases = [c for c in cases if len(c["data"]) < 50 * 1024 * 1024]

    if args.dry_run:
        print(f"{'Category':<30} {'Expected':<20} {'Size':>10}  Name")
        print("-" * 80)
        for c in cases:
            print(f"{c['category']:<30} {c['expected']:<20} {len(c['data']):>10}  {c['name']}")
        print(f"\nTotal: {len(cases)} files")
        return

    print(f"Connecting to storage account '{args.account_name}' …")
    service_client = get_service_client(args)
    container_client = service_client.get_container_client(args.container)

    # Ensure container exists
    try:
        container_client.create_container()
        print(f"Container '{args.container}' created.")
    except Exception:
        print(f"Container '{args.container}' already exists – reusing.")

    print(f"Uploading {len(cases)} test files using {args.threads} thread(s) …\n")

    results: list[UploadResult] = []
    lock = threading.Lock()
    queue = list(cases)
    total = len(queue)
    counter = [0]

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                case = queue.pop(0)
                counter[0] += 1
                idx = counter[0]

            result = upload_blob(container_client, case)
            status = "OK" if result.success else "FAIL"
            size_label = (
                f"{result.size_bytes / 1024 / 1024:.1f} MB"
                if result.size_bytes >= 1024 * 1024
                else f"{result.size_bytes / 1024:.1f} KB"
            )
            print(
                f"  [{idx:>3}/{total}] {status:<4}  {result.upload_ms:>8.0f}ms"
                f"  {size_label:>9}  {case['name']}"
            )

            with lock:
                results.append(result)

    threads = [threading.Thread(target=worker) for _ in range(args.threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print_summary(results)
    save_csv(results, args.output)


if __name__ == "__main__":
    main()
