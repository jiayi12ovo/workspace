#!/bin/bash
# 页缓存分析脚本 — 分析 buff/cache 中到底存了哪些文件
# 适用: 银河麒麟 V10 / Debian 系 Linux
# 用法: sudo bash analyze_cache.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  系统页缓存分析 (buff/cache)${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# ---------- 1. 检查依赖 ----------
echo -e "${YELLOW}[1/6] 检查依赖工具...${NC}"
MISSING=""
for tool in fincore bc find xargs awk lsof; do
    if ! which $tool &>/dev/null; then
        MISSING="$MISSING $tool"
    fi
done

if [ -n "$MISSING" ]; then
    echo "  缺少工具:$MISSING"
    echo "  尝试安装 fincore (linux-ftools)..."
    apt-get install -y linux-ftools 2>/dev/null || {
        echo -e "${RED}  安装失败，请手动执行: apt-get install linux-ftools${NC}"
        echo "  然后重跑本脚本。"
        exit 1
    }
fi
echo -e "  ${GREEN}依赖检查通过${NC}"
echo ""

# ---------- 2. 整体概况 ----------
echo -e "${YELLOW}[2/6] 整体内存/cache 概况${NC}"
free -h
echo ""
echo "--- 精确值 (/proc/meminfo) ---"
cat /proc/meminfo | grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|Shmem):" \
    | awk '{printf "  %-16s %10s %s\n", $1, $2, $3}'

BUFFERS=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
CACHED=$(awk '/^Cached:/{print $2}' /proc/meminfo)
SRECL=$(awk '/^SReclaimable:/{print $2}' /proc/meminfo)
TOTAL_BC=$(( (BUFFERS + CACHED + SRECL) / 1024 ))

echo ""
echo -e "  buff/cache 合计: ${BOLD}${TOTAL_BC} MB${NC}"
echo -e "    其中 Buffers(块设备缓冲):    $(( BUFFERS / 1024 )) MB"
echo -e "    其中 SReclaimable(slab):     $(( SRECL / 1024 )) MB"
echo -e "    其中 Cached(文件页缓存):     $(( CACHED / 1024 )) MB"
echo ""

# ---------- 3. slab 缓存 ----------
echo -e "${YELLOW}[3/6] Slab 缓存 (SReclaimable) 分析${NC}"
echo "  (dentry=目录项缓存, inode=索引节点缓存)"
cat /proc/slabinfo 2>/dev/null | awk 'NR==1 || NR==2 {print; next} $2>0' \
    | sort -t' ' -k3 -rn 2>/dev/null | head -12 \
    | awk '{printf "  %-30s objects=%8s  obj_size=%5s  pages=%8s\n", $1, $2, $3, $3*$2/4096}'
echo ""

# ---------- 4. 页缓存按目录分布 ----------
echo -e "${YELLOW}[4/6] 页缓存 (Cached) 按目录分布${NC}"
echo "  扫描中，约需 1-2 分钟..."
echo ""

scan_dir() {
    local dir="$1"
    local label="$2"
    if [ ! -d "$dir" ]; then
        echo "  $label: 目录不存在，跳过"
        return
    fi
    # 用 fincore -b 精确统计
    local result
    result=$(find "$dir" -type f 2>/dev/null | xargs fincore -b 2>/dev/null \
        | awk 'NR>1 && $1>0 {cached+=$1; files++} END {
            printf "  %-25s  %6d 文件有缓存  %7.0f MB\n", "'"$label"'", files, cached/1024/1024
        }')
    echo "$result"
}

TOTAL_CACHED_MB=$(( CACHED / 1024 ))
echo "  (系统总页缓存: ${TOTAL_CACHED_MB} MB, 以下为逐目录扫描)"
echo ""

scan_dir /var/log      "/var/log (日志)"
scan_dir /usr/lib      "/usr/lib (系统库)"
scan_dir /usr/share    "/usr/share (共享数据)"
scan_dir /opt          "/opt (第三方应用)"
scan_dir /home         "/home (用户数据)"
scan_dir /var/cache    "/var/cache (应用缓存)"
scan_dir /var/lib      "/var/lib (运行时数据)"
scan_dir /etc          "/etc (配置文件)"
echo ""

# ---------- 5. 最大的缓存文件 TOP 20 ----------
echo -e "${YELLOW}[5/6] 页缓存中最大的文件 TOP 20 (扫描 /var /usr /opt)${NC}"
{
    find /var/log /var/lib /usr/lib /opt -type f -size +100k 2>/dev/null
} | xargs fincore -b 2>/dev/null \
    | awk 'NR>1 && $1>0 {printf "%s\t%s\t%s\n", $1, $2, $4}' \
    | sort -t$'\t' -k1 -rn | head -20 \
    | awk -F'\t' '{
        mb = $1/1024/1024;
        pages = $2;
        file = $3;
        if (length(file) > 70) file = "..." substr(file, length(file)-67);
        printf "  %7.1f MB  (%7d 页)  %s\n", mb, pages, file
    }'
echo ""

# ---------- 6. 进程打开文件数 TOP 15 + 进程内存 TOP 15 ----------
echo -e "${YELLOW}[6/6] 进程情况${NC}"

echo ""
echo "  --- 打开文件数 TOP 15 (进程) ---"
echo "  (打开文件多 → 消耗大量 dentry/inode slab 缓存)"
lsof -n 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -15 \
    | awk '{printf "  %7d 个文件  %s\n", $1, $2}'

echo ""
echo "  --- 内存占用 TOP 15 (RSS) ---"
ps aux --sort=-rss 2>/dev/null | head -16 \
    | awk 'NR==1{printf "  %-6s %-20s %6s %6s %s\n", "PID", "USER", "%MEM", "RSS(MB)", "COMMAND"}
           NR>1{printf "  %-6s %-20s %5s%% %6d  %s\n", $2, $1, $4, $6/1024, $11}'

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  分析完成${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "  关键数字:"
echo "    总 buff/cache:   ${TOTAL_BC} MB"
echo "    - Buffers:       $(( BUFFERS / 1024 )) MB (块设备缓冲)"
echo "    - SReclaimable:  $(( SRECL / 1024 )) MB (dentry/inode slab)"
echo "    - Cached:        $(( CACHED / 1024 )) MB (文件页缓存)"
echo ""
echo "  页缓存主要消耗者是上面[4/6]扫描结果中最大的目录。"
echo "  如需释放缓存: echo 3 > /proc/sys/vm/drop_caches"
echo "  (仅释放内存副本，不删除磁盘文件)"
