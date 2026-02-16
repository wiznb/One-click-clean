#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# 系统清理脚本（Ubuntu / Debian / CentOS / RHEL / Alma / Rocky）
# - 自动清理无用包、缓存、残留 rc 包
# - 清理 journald 日志（默认保留到 50M）
# - 清理旧内核（仅移除非当前运行内核的版本包）
# =========================================================

JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-50M}"   # 可改：例如 200M
YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    *) ;;
  esac
done

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

hr() { echo "------------------------------------------------------------"; }

confirm() {
  if [[ "$YES" -eq 1 ]]; then return 0; fi
  read -r -p "确认开始清理？(Y/N): " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

show_disk() {
  hr
  echo "磁盘占用："
  df -h /
  hr
}

vacuum_journal() {
  if have_cmd journalctl; then
    echo "[*] 清理 journald 日志（vacuum-size=${JOURNAL_VACUUM_SIZE}）..."
    journalctl --rotate || true
    journalctl --vacuum-size="${JOURNAL_VACUUM_SIZE}" || true
  else
    echo "[*] 未发现 journalctl，跳过 journald 清理。"
  fi
}

clean_debian_like() {
  echo "[*] 识别为 Debian/Ubuntu 系..."
  echo "[*] 清理无用依赖..."
  apt-get autoremove --purge -y

  echo "[*] 清理 apt 缓存..."
  apt-get clean -y
  apt-get autoclean -y

  echo "[*] 清理 dpkg 残留 rc 配置包..."
  mapfile -t rc_pkgs < <(dpkg -l | awk '/^rc/ {print $2}' || true)
  if [[ "${#rc_pkgs[@]}" -gt 0 ]]; then
    apt-get purge -y "${rc_pkgs[@]}" || true
  else
    echo "    - 无 rc 残留包"
  fi

  vacuum_journal

  echo "[*] 清理旧内核（保留当前运行内核：$(uname -r)）..."
  running="$(uname -r)"

  # 只匹配“带具体版本号”的内核相关包，避免误伤 meta 包（如 linux-image-generic）
  mapfile -t old_kernel_pkgs < <(
    dpkg -l | awk '/^ii/ {print $2}' \
      | grep -E '^(linux-image|linux-headers|linux-modules|linux-modules-extra)-[0-9]' \
      | grep -vF "$running" \
      || true
  )

  if [[ "${#old_kernel_pkgs[@]}" -gt 0 ]]; then
    echo "    - 将移除以下旧内核包："
    printf "      %s\n" "${old_kernel_pkgs[@]}"
    apt-get purge -y "${old_kernel_pkgs[@]}" || true
    apt-get autoremove --purge -y || true
  else
    echo "    - 未发现可清理的旧内核版本包"
  fi
}

clean_rhel_like() {
  echo "[*] 识别为 CentOS/RHEL/Alma/Rocky 系..."

  if have_cmd dnf; then
    PM=dnf
  else
    PM=yum
  fi

  echo "[*] 清理无用依赖..."
  if [[ "$PM" == "dnf" ]]; then
    dnf -y autoremove || true
    echo "[*] 清理缓存..."
    dnf -y clean all || true
  else
    yum -y autoremove || true
    echo "[*] 清理缓存..."
    yum -y clean all || true
  fi

  vacuum_journal

  echo "[*] 清理旧内核（尽量保留当前运行内核：$(uname -r)）..."
  if have_cmd dnf; then
    # repoquery 在 dnf-plugins-core 里，可能不存在；存在就用它清理 installonly 的旧内核
    if dnf -q repoquery --help >/dev/null 2>&1; then
      # --latest-limit=-1 => 除最新外全部（对 installonly 包）
      old="$(dnf repoquery --installonly --latest-limit=-1 -q 2>/dev/null || true)"
      if [[ -n "${old// }" ]]; then
        echo "    - 将移除以下旧内核/安装保留包："
        echo "$old"
        dnf -y remove $old || true
      else
        echo "    - 未发现可清理的旧内核（或 repoquery 无结果）"
      fi
    else
      echo "    - 未安装 dnf repoquery（dnf-plugins-core），跳过旧内核自动清理"
    fi
  else
    # yum 系：如果有 package-cleanup（yum-utils），可清理旧内核
    if have_cmd package-cleanup; then
      # 保留 1 个最新内核（你也可以改成 --count=2）
      package-cleanup -y --oldkernels --count=1 || true
    else
      echo "    - 未安装 package-cleanup（yum-utils），跳过旧内核自动清理"
    fi
  fi
}

main() {
  need_root
  show_disk
  confirm

  if [[ -f /etc/debian_version ]] || (have_cmd apt-get && [[ -f /etc/os-release ]]); then
    clean_debian_like
  elif [[ -f /etc/redhat-release ]] || have_cmd yum || have_cmd dnf; then
    clean_rhel_like
  else
    echo "未识别的系统（仅支持 Debian/Ubuntu/CentOS/RHEL/Alma/Rocky）。"
    exit 1
  fi

  echo
  echo "[✓] 清理完成！"
  show_disk
}

main "$@"
