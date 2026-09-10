#!/bin/bash
# Record WeChat disk usage and memory for periodic trend comparison.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  Scripts/measure-wechat-usage.sh [--label text] [--root path] [--app-path path] [--out file]

Examples:
  Scripts/measure-wechat-usage.sh
  Scripts/measure-wechat-usage.sh --label weekly-check
  Scripts/measure-wechat-usage.sh --app-path /Applications/WeChat.app

By default, results are appended to:
  ~/Documents/WeVault-WeChat-Usage/wechat-usage-history.csv
USAGE
}

label="auto"
app_path="/Applications/WeChat.app"
roots=()
out="$HOME/Documents/WeVault-WeChat-Usage/wechat-usage-history.csv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      [[ $# -ge 2 ]] || { echo "Missing value for --label" >&2; exit 2; }
      label="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || { echo "Missing value for --root" >&2; exit 2; }
      roots+=("$2")
      shift 2
      ;;
    --app-path)
      [[ $# -ge 2 ]] || { echo "Missing value for --app-path" >&2; exit 2; }
      app_path="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { echo "Missing value for --out" >&2; exit 2; }
      out="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    value = bytes + 0
    i = 1
    while (value >= 1024 && i < 5) {
      value /= 1024
      i++
    }
    if (i == 1) printf "%.0f %s", value, unit[i]
    else printf "%.2f %s", value, unit[i]
  }'
}

csv_escape() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "$value"
}

canonical_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  (cd "$dir" && pwd -P)
}

declare -a selected_roots=()

add_root() {
  local path="$1"
  local resolved
  resolved="$(canonical_dir "$path")" || return 0
  local existing
  if [[ ${#selected_roots[@]} -gt 0 ]]; then
    for existing in "${selected_roots[@]}"; do
      if [[ "$resolved" == "$existing" || "$resolved" == "$existing/"* ]]; then
        return 0
      fi
    done
  fi
  selected_roots+=("$resolved")
}

if [[ ${#roots[@]} -eq 0 ]]; then
  roots=(
    "$HOME/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"
    "$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents"
    "$HOME/Library/Application Support/com.tencent.xinWeChat"
    "$HOME/Library/Application Support/WeChat"
  )
fi

for root in "${roots[@]}"; do
  add_root "$root"
done

if [[ ${#selected_roots[@]} -eq 0 ]]; then
  echo "没有找到微信数据目录。可以用 --root 手动指定微信数据目录。" >&2
  exit 1
fi

resolved_app_path="$(canonical_dir "$app_path")" || {
  echo "没有找到微信 App：$app_path。可以用 --app-path 指定真实路径。" >&2
  exit 1
}
app_prefix="$resolved_app_path/"

process_rows="$(ps -axo pid=,rss=,etime=,comm= | awk -v prefix="$app_prefix" '
  {
    pid = $1
    rss = $2
    etime = $3
    comm = substr($0, index($0, $4))
    if (comm == prefix || index(comm, prefix) == 1) {
      printf "%s,%s,%s,%s\n", pid, rss, etime, comm
    }
  }
')"

if [[ -z "$process_rows" ]]; then
  echo "没有发现正在运行的微信进程。请先启动微信，再运行脚本。" >&2
  exit 1
fi

process_count="$(printf '%s\n' "$process_rows" | awk 'END {print NR}')"
rss_bytes="$(printf '%s\n' "$process_rows" | awk -F, '{total += $2 * 1024} END {printf "%d", total}')"
main_etime="$(printf '%s\n' "$process_rows" | awk -F, '$4 ~ /\/Contents\/MacOS\/WeChat$/ {print $3; exit}')"
main_etime="${main_etime:-unknown}"

wevault_stats="$(ps -axo rss=,comm= | awk '
  /\/WeVault\.app\/Contents\/MacOS\/WeVault$/ {
    total += $1 * 1024
    count += 1
  }
  END { printf "%d %d", total, count }
')"
wevault_rss_bytes="${wevault_stats%% *}"
wevault_process_count="${wevault_stats##* }"

parse_footprint_field() {
  local field="$1"
  awk -v field="$field" '
  function multiplier(unit) {
    if (unit == "B") return 1
    if (unit == "KB") return 1024
    if (unit == "MB") return 1024 * 1024
    if (unit == "GB") return 1024 * 1024 * 1024
    return 1
  }
  $1 == field ":" {
    total += $2 * multiplier($3)
  }
  END { printf "%d", total }
  '
}

footprint_bytes=0
footprint_peak_bytes=0
footprint_process_count=0
footprint_warning=""
while IFS=, read -r pid _rss _etime _comm; do
  footprint_output="$(footprint -p "$pid" 2>/dev/null || true)"
  process_footprint="$(printf '%s\n' "$footprint_output" | parse_footprint_field "phys_footprint")"
  process_peak="$(printf '%s\n' "$footprint_output" | parse_footprint_field "phys_footprint_peak")"
  if [[ -n "$process_footprint" && "$process_footprint" != "0" ]]; then
    footprint_bytes=$((footprint_bytes + process_footprint))
    footprint_peak_bytes=$((footprint_peak_bytes + process_peak))
    footprint_process_count=$((footprint_process_count + 1))
  else
    footprint_warning="${footprint_warning} PID $pid"
  fi
done <<< "$process_rows"

if [[ -z "$footprint_bytes" || "$footprint_bytes" == "0" ]]; then
  echo "footprint 未能读取微信内存，已退出；请确认当前终端有权限查看进程信息。" >&2
  exit 1
fi
if [[ "$footprint_process_count" != "$process_count" ]]; then
  echo "footprint 只读取到 $footprint_process_count / $process_count 个微信进程，进程可能正在变化；请稍后重跑。" >&2
  exit 1
fi

du_error="$(mktemp "${TMPDIR:-/tmp}/wevault-du-error.XXXXXX")"
du_output=""
if ! du_output="$(du -sk "${selected_roots[@]}" 2>"$du_error")"; then
  du_warning="$(tr '\n' ' ' < "$du_error")"
else
  du_warning=""
fi
disk_bytes="$(printf '%s\n' "$du_output" | awk '{total += $1 * 1024} END {printf "%d", total}')"
if [[ -z "$disk_bytes" || "$disk_bytes" == "0" ]]; then
  echo "无法读取微信文件占用。请检查终端是否有 Full Disk Access，或用 --root 指定可读目录。" >&2
  exit 1
fi

timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
disk_mib="$(awk -v bytes="$disk_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
rss_mib="$(awk -v bytes="$rss_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
footprint_mib="$(awk -v bytes="$footprint_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
footprint_peak_mib="$(awk -v bytes="$footprint_peak_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
wevault_rss_mib="$(awk -v bytes="$wevault_rss_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')"
roots_joined="$(printf '%s;' "${selected_roots[@]}")"

header="timestamp,label,wechat_disk_bytes,wechat_disk_mib,wechat_rss_bytes,wechat_rss_mib,wechat_phys_footprint_bytes,wechat_phys_footprint_mib,wechat_phys_footprint_peak_bytes,wechat_phys_footprint_peak_mib,wechat_process_count,wechat_main_etime,wevault_rss_bytes,wevault_rss_mib,wevault_process_count,wechat_app_path,roots"

if [[ "$out" != "/dev/null" ]]; then
  mkdir -p "$(dirname "$out")"
  if [[ -f "$out" && -s "$out" ]]; then
    existing_header="$(sed -n '1p' "$out")"
    if [[ "$existing_header" != "$header" ]]; then
      legacy_out="${out}.legacy-$(date '+%Y%m%d%H%M%S')"
      mv "$out" "$legacy_out"
      printf '旧记录口径不同，已备份：%s\n' "$legacy_out"
    fi
  fi
  if [[ ! -f "$out" ]]; then
    printf '%s\n' "$header" > "$out"
  fi

  {
    printf '%s,' "$timestamp"
    csv_escape "$label"; printf ','
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
      "$disk_bytes" "$disk_mib" "$rss_bytes" "$rss_mib" \
      "$footprint_bytes" "$footprint_mib" "$footprint_peak_bytes" "$footprint_peak_mib" "$process_count"
    csv_escape "$main_etime"; printf ','
    printf '%s,%s,%s,' "$wevault_rss_bytes" "$wevault_rss_mib" "$wevault_process_count"
    csv_escape "$resolved_app_path"; printf ','
    csv_escape "$roots_joined"; printf '\n'
  } >> "$out"

  first_line="$(sed -n '2p' "$out" || true)"
  previous_line="$(tail -n 2 "$out" | head -n 1 || true)"
else
  first_line=""
  previous_line=""
fi

csv_column() {
  awk -v index="$1" -F, '{print $index}' | tr -d '"'
}

print_delta() {
  local title="$1"
  local line="$2"
  local column="$3"
  local current="$4"
  [[ -n "$line" && "$line" != "$timestamp,"* ]] || return 0
  local base
  base="$(printf '%s\n' "$line" | csv_column "$column")"
  [[ "$base" =~ ^[0-9]+$ ]] || return 0
  local delta=$((base - current))
  if (( delta >= 0 )); then
    printf '%s：少了 %s\n' "$title" "$(human_bytes "$delta")"
  else
    printf '%s：多了 %s\n' "$title" "$(human_bytes "$((-delta))")"
  fi
}

printf '本次记录：%s（%s）\n' "$timestamp" "$label"
printf '微信文件占用：%s\n' "$(human_bytes "$disk_bytes")"
printf '微信内存 footprint：%s（更接近活动监视器）\n' "$(human_bytes "$footprint_bytes")"
printf '微信 RSS：%s（辅助参考）\n' "$(human_bytes "$rss_bytes")"
printf '微信进程数：%s，主进程运行时长：%s\n' "$process_count" "$main_etime"
printf 'WeVault 自身 RSS：%s（进程数：%s）\n' "$(human_bytes "$wevault_rss_bytes")" "$wevault_process_count"
print_delta "文件相比上一次记录" "$previous_line" 3 "$disk_bytes"
print_delta "内存相比上一次记录" "$previous_line" 7 "$footprint_bytes"
print_delta "文件相比最早记录" "$first_line" 3 "$disk_bytes"
print_delta "内存相比最早记录" "$first_line" 7 "$footprint_bytes"
printf '记录文件：%s\n' "$out"
printf '微信 App：%s\n' "$resolved_app_path"
printf '统计目录：\n'
for root in "${selected_roots[@]}"; do
  printf '  %s\n' "$root"
done
if [[ -n "$du_warning" ]]; then
  printf '目录读取警告：%s\n' "$du_warning"
fi
