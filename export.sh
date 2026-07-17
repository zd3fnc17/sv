#!/usr/bin/env bash
#
# pve-backup.sh
# Backup VM/CT Proxmox ke zstd, lalu sajikan hasilnya via HTTP untuk di-download.
#
# Alur:
#   1. Bersihkan /var/lib/vz/dump (hapus semua backup lama tanpa konfirmasi)
#   2. Tanya ID mana yang mau di-backup (contoh: 100,101,103-105)
#   3. Jalankan vzdump --compress zstd untuk tiap ID
#   4. Nyalakan HTTP server (python) dan tampilkan link download tiap file
#
# Jalankan sebagai root:  sudo ./pve-backup.sh
#

set -uo pipefail

# ------------------------------------------------------------------
# Konfigurasi (silakan diubah sesuai kebutuhan)
# ------------------------------------------------------------------
DUMP_DIR="/var/lib/vz/dump"   # lokasi hasil backup
HTTP_PORT="8000"              # port untuk HTTP server
BACKUP_MODE="snapshot"        # snapshot | suspend | stop
ZSTD_THREADS="0"             # 0 = pakai semua core CPU
# ------------------------------------------------------------------

# Warna sederhana untuk output
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_BLUE="\033[1;36m"
C_RESET="\033[0m"

info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# ------------------------------------------------------------------
# Cek prasyarat
# ------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    err "Script harus dijalankan sebagai root. Coba: sudo $0"
    exit 1
fi

if ! command -v vzdump >/dev/null 2>&1; then
    err "Perintah 'vzdump' tidak ditemukan. Pastikan ini dijalankan di host Proxmox."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    err "python3 tidak ditemukan. Install dulu: apt install python3"
    exit 1
fi

mkdir -p "$DUMP_DIR"

# ------------------------------------------------------------------
# 1. Hapus backup lama tanpa konfirmasi
# ------------------------------------------------------------------
info "Memeriksa isi ${DUMP_DIR} ..."
shopt -s nullglob
old_files=("$DUMP_DIR"/*)
if [[ ${#old_files[@]} -gt 0 ]]; then
    warn "Ditemukan ${#old_files[@]} item lama, menghapus semuanya..."
    rm -rf "${DUMP_DIR:?}"/*
    ok "Backup lama sudah dihapus."
else
    info "Direktori sudah kosong, tidak ada yang perlu dihapus."
fi
shopt -u nullglob

# ------------------------------------------------------------------
# 2. Tanya ID yang ingin di-backup
# ------------------------------------------------------------------
echo
info "Daftar VM/CT yang tersedia:"
if command -v qm  >/dev/null 2>&1; then qm  list  2>/dev/null || true; fi
if command -v pct >/dev/null 2>&1; then pct list 2>/dev/null || true; fi
echo

echo -e "Masukkan ID yang ingin di-backup."
echo -e "  - Pisahkan dengan koma untuk beberapa ID, contoh: ${C_GREEN}100,101,105${C_RESET}"
echo -e "  - Gunakan tanda hubung untuk rentang, contoh: ${C_GREEN}100-105${C_RESET}"
echo -e "  - Bisa dikombinasi, contoh: ${C_GREEN}100,102-104,110${C_RESET}"
echo
read -rp "ID backup: " raw_input

if [[ -z "${raw_input// }" ]]; then
    err "Input kosong. Keluar."
    exit 1
fi

# ------------------------------------------------------------------
# Parsing input: expand koma & rentang jadi daftar ID unik
# ------------------------------------------------------------------
declare -a IDS=()
IFS=',' read -ra parts <<< "$raw_input"
for part in "${parts[@]}"; do
    part="${part// /}"                       # buang spasi
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        start="${part%-*}"
        end="${part#*-}"
        if (( start > end )); then
            err "Rentang tidak valid: $part (awal lebih besar dari akhir)"
            exit 1
        fi
        for (( i=start; i<=end; i++ )); do IDS+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
        IDS+=("$part")
    else
        err "Format ID tidak dikenal: '$part'"
        exit 1
    fi
done

# Buang duplikat, urutkan
mapfile -t IDS < <(printf '%s\n' "${IDS[@]}" | sort -n -u)

if [[ ${#IDS[@]} -eq 0 ]]; then
    err "Tidak ada ID valid yang bisa diproses."
    exit 1
fi

echo
ok "ID yang akan di-backup: ${IDS[*]}"
echo

# ------------------------------------------------------------------
# 3. Jalankan vzdump untuk tiap ID
# ------------------------------------------------------------------
declare -a SUCCESS_IDS=()
declare -a FAILED_IDS=()

for id in "${IDS[@]}"; do
    info "Mem-backup ID ${id} ..."
    if vzdump "$id" \
        --compress zstd \
        --zstd "$ZSTD_THREADS" \
        --mode "$BACKUP_MODE" \
        --dumpdir "$DUMP_DIR"; then
        ok "Backup ID ${id} selesai."
        SUCCESS_IDS+=("$id")
    else
        err "Backup ID ${id} GAGAL."
        FAILED_IDS+=("$id")
    fi
    echo
done

echo "------------------------------------------------------------"
ok "Berhasil : ${SUCCESS_IDS[*]:-(tidak ada)}"
[[ ${#FAILED_IDS[@]} -gt 0 ]] && warn "Gagal    : ${FAILED_IDS[*]}"
echo "------------------------------------------------------------"
echo

# Kalau tidak ada file hasil, tidak perlu nyalakan server
shopt -s nullglob
result_files=("$DUMP_DIR"/*.zst)
shopt -u nullglob
if [[ ${#result_files[@]} -eq 0 ]]; then
    err "Tidak ada file backup (.zst) yang dihasilkan. Server tidak dinyalakan."
    exit 1
fi

# ------------------------------------------------------------------
# 4. Nyalakan HTTP server + tampilkan link download
# ------------------------------------------------------------------
# Ambil IP utama host
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$HOST_IP" ]] && HOST_IP="127.0.0.1"

info "Menyalakan HTTP server di port ${HTTP_PORT} untuk direktori ${DUMP_DIR} ..."
python3 -m http.server "$HTTP_PORT" --directory "$DUMP_DIR" >/dev/null 2>&1 &
SERVER_PID=$!

# Fungsi bersih-bersih saat keluar
cleanup() {
    echo
    info "Mematikan HTTP server (PID ${SERVER_PID}) ..."
    kill "$SERVER_PID" >/dev/null 2>&1
    ok "Server dihentikan. Sampai jumpa!"
    exit 0
}
trap cleanup INT TERM

sleep 1  # beri waktu server siap

echo
echo -e "${C_GREEN}===================== LINK DOWNLOAD =====================${C_RESET}"
for f in "${result_files[@]}"; do
    fname="$(basename "$f")"
    fsize="$(du -h "$f" | awk '{print $1}')"
    # URL-encode nama file (spasi -> %20) supaya link aman
    encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$fname")"
    echo -e "  ${fname} (${fsize})"
    echo -e "    ${C_BLUE}http://${HOST_IP}:${HTTP_PORT}/${encoded}${C_RESET}"
done
echo -e "${C_GREEN}=========================================================${C_RESET}"
echo
info "Buka link di atas dari browser/wget/curl untuk mengunduh backup."
echo
echo -e "${C_YELLOW}>> Setelah selesai men-download, tekan CTRL+C untuk keluar"
echo -e "   dan mematikan HTTP server.${C_RESET}"
echo

# Tahan script tetap hidup selama server jalan
wait "$SERVER_PID"
