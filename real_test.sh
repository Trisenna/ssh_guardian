#!/bin/bash
# real_test.sh — 2 核 2GB 服务器真实环境测试脚本
#
# 此脚本在目标服务器上运行，自动完成：
#   1. 编译 ssh_guardian
#   2. 检查 localhost SSH 公钥认证
#   3. 启动 ssh_guardian（真实模式）
#   4. 启动 stress_training.py 打满资源
#   5. 等待 ssh_guardian 自动清杀 stress 进程
#   6. 验证结果
#
# ⚠️  警告：此脚本会让服务器暂时变得非常卡！
#     请确保你有其他方式（如控制台/VNC）可以访问服务器，以防万一。
#     建议在测试专用服务器上运行，不要在生产机上跑。
#
# 用法：bash real_test.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  ssh_guardian 真实环境端到端测试${NC}"
echo -e "${CYAN}  目标环境: 2 核 2GB 服务器${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDIAN_SRC="$SCRIPT_DIR/ssh_guardian.c"
GUARDIAN_BIN="$SCRIPT_DIR/ssh_guardian"
STRESS_PY="$SCRIPT_DIR/stress_training.py"
LOG_DIR="$SCRIPT_DIR/real_test_logs"
DISK_LOG="$LOG_DIR/guardian.log"
SHM_LOG="/dev/shm/ssh_guardian_realtest.log"

mkdir -p "$LOG_DIR"

# ================================================================
# 前置检查
# ================================================================

echo -e "${YELLOW}[检查] 系统环境...${NC}"

# 内存
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
echo "  总内存: ${MEM_MB} MB"

if [ "$MEM_MB" -gt 4096 ]; then
    echo -e "  ${YELLOW}⚠️  内存超过 4GB，stress 默认参数可能不够打满${NC}"
    echo -e "  ${YELLOW}   建议加参数: python3 stress_training.py --mem-mb $((MEM_MB - 400))${NC}"
fi

# CPU
CPUS=$(nproc)
echo "  CPU 核数: $CPUS"

# Python3
if ! command -v python3 &>/dev/null; then
    echo -e "  ${RED}✗ python3 未安装，无法运行 stress_training.py${NC}"
    exit 1
fi
echo "  Python3: $(python3 --version)"

# GCC
if ! command -v gcc &>/dev/null; then
    echo -e "  ${RED}✗ gcc 未安装，无法编译 ssh_guardian${NC}"
    exit 1
fi
echo "  GCC: $(gcc --version | head -1)"

# SSH localhost
echo ""
echo -e "${YELLOW}[检查] localhost SSH 公钥认证...${NC}"
if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no localhost /bin/true 2>/dev/null; then
    echo -e "  ${GREEN}✓ ssh localhost /bin/true 成功${NC}"
else
    echo -e "  ${RED}✗ ssh localhost 失败${NC}"
    echo ""
    echo "  请先设置 localhost 公钥认证："
    echo "    1. ssh-keygen -t ed25519    (如果还没有密钥)"
    echo "    2. ssh-copy-id localhost"
    echo "    3. ssh -o BatchMode=yes localhost /bin/true  (验证)"
    echo ""
    exit 1
fi

# core dump
echo ""
echo -e "${YELLOW}[检查] core dump 设置...${NC}"
CORE_LIMIT=$(ulimit -c)
echo "  当前 ulimit -c: $CORE_LIMIT"
if [ "$CORE_LIMIT" != "0" ]; then
    echo -e "  ${YELLOW}⚠️  建议在当前 shell 执行: ulimit -c 0${NC}"
    echo "  （本脚本会自动为 stress 进程设置）"
fi

CORE_PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "unknown")
echo "  core_pattern: $CORE_PATTERN"

# ================================================================
# 编译
# ================================================================

echo ""
echo -e "${YELLOW}[编译] ssh_guardian...${NC}"

# 尝试静态编译
if gcc -static -O2 -o "$GUARDIAN_BIN" "$GUARDIAN_SRC" 2>/dev/null; then
    echo -e "  ${GREEN}✓ 静态编译成功${NC}"
elif gcc -O2 -o "$GUARDIAN_BIN" "$GUARDIAN_SRC" 2>/dev/null; then
    echo -e "  ${GREEN}✓ 动态编译成功${NC}（静态编译不可用）"
else
    echo -e "  ${RED}✗ 编译失败${NC}"
    gcc -O2 -o "$GUARDIAN_BIN" "$GUARDIAN_SRC" 2>&1
    exit 1
fi

# ================================================================
# 确认
# ================================================================

echo ""
echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
echo -e "${RED}  ⚠️  警告：即将开始真实压力测试！${NC}"
echo -e "${RED}${NC}"
echo -e "${RED}  此测试会：${NC}"
echo -e "${RED}    - 吞掉大部分内存（~1.4GB / 2GB）${NC}"
echo -e "${RED}    - 制造高强度磁盘 I/O${NC}"
echo -e "${RED}    - 服务器会变得非常卡，SSH 可能暂时断开${NC}"
echo -e "${RED}    - ssh_guardian 应该会在 ~30 秒内杀掉压力进程${NC}"
echo -e "${RED}${NC}"
echo -e "${RED}  确保你有备用访问方式（控制台/VNC/物理访问）！${NC}"
echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -n "  输入 yes 继续，其他任意键退出: "
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "  已取消。"
    exit 0
fi

# ================================================================
# 启动 ssh_guardian
# ================================================================

echo ""
echo -e "${CYAN}[启动] ssh_guardian...${NC}"

# 清理旧日志
rm -f "$DISK_LOG" "$SHM_LOG"

# 适合 2GB 服务器的参数：
#   --interval 3      : 每 3 秒检测一次（比默认更频繁，加快响应）
#   --fail-threshold 2 : 连续 2 次失败就触发（测试用，生产建议 3）
#   --cooldown 60      : 冷却 60 秒
#   --min-rss-mb 100   : RSS > 100MB 的 python3 就是候选
#   --recovery-wait 5  : 第一级杀完等 5 秒
"$GUARDIAN_BIN" \
    --interval 3 \
    --timeout 8 \
    --fail-threshold 2 \
    --cooldown 60 \
    --kill-count 1 \
    --min-rss-mb 100 \
    --recovery-wait 5 \
    --allow python3,python \
    --exclude bash,zsh,sh,fish,tmux,screen,sshd,ssh,login,jupyter-lab,jupyter-notebook \
    --log-file "$DISK_LOG" \
    --shm-log "$SHM_LOG" \
    2>"$LOG_DIR/guardian_stderr.log" &
GUARDIAN_PID=$!

echo "  ssh_guardian PID: $GUARDIAN_PID"
echo "  磁盘日志: $DISK_LOG"
echo "  SHM 日志: $SHM_LOG"
sleep 2

if ! kill -0 "$GUARDIAN_PID" 2>/dev/null; then
    echo -e "  ${RED}✗ ssh_guardian 启动失败${NC}"
    cat "$LOG_DIR/guardian_stderr.log"
    exit 1
fi
echo -e "  ${GREEN}✓ ssh_guardian 正在运行${NC}"

# ================================================================
# 启动压力测试
# ================================================================

echo ""
echo -e "${CYAN}[启动] stress_training.py...${NC}"
echo "  服务器即将变卡，请耐心等待..."
echo ""

# 计算合理的内存目标（总内存的 75%，至少留一点给系统）
STRESS_MEM=$(( MEM_MB * 75 / 100 ))
if [ "$STRESS_MEM" -lt 500 ]; then
    STRESS_MEM=500
fi
if [ "$STRESS_MEM" -gt 1600 ]; then
    STRESS_MEM=1400  # 对 2GB 机器封顶 1400
fi

echo "  内存目标: ${STRESS_MEM} MB"

ulimit -c 0

python3 "$STRESS_PY" \
    --mem-mb "$STRESS_MEM" \
    --io-workers 4 \
    --chunk-mb 50 \
    --countdown 5 \
    >"$LOG_DIR/stress_stdout.log" 2>&1 &
STRESS_PID=$!

echo "  stress_training PID: $STRESS_PID"

# ================================================================
# 等待结果
# ================================================================

echo ""
echo -e "${CYAN}[等待] 观察 ssh_guardian 的反应...${NC}"
echo "  每 5 秒检查一次 stress 进程是否还在"
echo ""

MAX_WAIT=180  # 最多等 3 分钟
ELAPSED=0
STRESS_KILLED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))

    if ! kill -0 "$STRESS_PID" 2>/dev/null; then
        STRESS_KILLED=1
        echo ""
        echo -e "  ${GREEN}✓ stress 进程已消失（+${ELAPSED}s）${NC}"
        break
    fi

    # 显示一些状态
    MEM_AVAIL=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    SWAP_USED=$(awk '/SwapTotal/ {total=$2} /SwapFree/ {free=$2} END {printf "%d", (total-free)/1024}' /proc/meminfo 2>/dev/null || echo "?")

    # 读最新 fail count
    LAST_FAIL=""
    if [ -f "$SHM_LOG" ]; then
        LAST_FAIL=$(grep -o 'FAILED ([0-9]*/[0-9]*)' "$SHM_LOG" 2>/dev/null | tail -1)
    fi

    echo "  +${ELAPSED}s | MemAvail=${MEM_AVAIL}MB SwapUsed=${SWAP_USED}MB | stress pid=$STRESS_PID 存活 | $LAST_FAIL"
done

# ================================================================
# 停止 guardian
# ================================================================

echo ""
echo -e "${CYAN}[清理] 停止 ssh_guardian...${NC}"

# 先等几秒让 guardian 完成恢复日志写入
sleep 5

kill "$GUARDIAN_PID" 2>/dev/null
wait "$GUARDIAN_PID" 2>/dev/null || true

# 清杀可能残留的 stress
if kill -0 "$STRESS_PID" 2>/dev/null; then
    kill -9 "$STRESS_PID" 2>/dev/null || true
fi

# 清理 I/O 临时文件
rm -rf /tmp/stress_io 2>/dev/null || true

# ================================================================
# 结果分析
# ================================================================

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  测试结果${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$STRESS_KILLED" -eq 1 ]; then
    echo -e "  ${GREEN}✓ stress 进程被成功清杀${NC}"
else
    echo -e "  ${RED}✗ stress 进程在 ${MAX_WAIT}s 内未被杀掉${NC}"
fi

# 检查日志
echo ""
echo "  日志分析："

for LOG_FILE in "$SHM_LOG" "$DISK_LOG"; do
    if [ ! -f "$LOG_FILE" ]; then
        continue
    fi
    echo ""
    echo "  --- $(basename "$LOG_FILE") ---"

    if grep -q "TRIGGER" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓ 检测到 TRIGGER（触发清杀）${NC}"
        grep "TRIGGER" "$LOG_FILE" | head -1 | sed 's/^/    /'
    fi

    if grep -q "STAGE1" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓ Stage 1 清杀已执行${NC}"
        grep "STAGE1" "$LOG_FILE" | head -3 | sed 's/^/    /'
    fi

    if grep -q "KILL.*python" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓ 杀掉了 python 进程${NC}"
        grep "KILL.*python" "$LOG_FILE" | sed 's/^/    /'
    fi

    if grep -q "STAGE2" "$LOG_FILE"; then
        echo -e "  ${YELLOW}ℹ Stage 2 也被触发了（Stage 1 不够）${NC}"
        grep "STAGE2" "$LOG_FILE" | head -3 | sed 's/^/    /'
    fi

    if grep -q "recovered" "$LOG_FILE" || grep -q "RECOVERY" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓ SSH 恢复确认${NC}"
        grep -E "(recovered|RECOVERY)" "$LOG_FILE" | head -3 | sed 's/^/    /'
    fi

    if grep -q "ring buffer flushed" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓ 环形缓冲区已补写到磁盘${NC}"
    fi
done

echo ""
echo "  完整日志文件："
echo "    SHM 日志:        $SHM_LOG"
echo "    磁盘日志:        $DISK_LOG"
echo "    Guardian stderr: $LOG_DIR/guardian_stderr.log"
echo "    Stress stdout:   $LOG_DIR/stress_stdout.log"
echo ""

if [ "$STRESS_KILLED" -eq 1 ]; then
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  测试通过！ssh_guardian 成功检测到 SSH 故障并自动恢复。${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
else
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  测试未通过。请检查上面的日志分析。${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  可能原因："
    echo "    1. 内存压力不够大，SSH 没有真正断开"
    echo "       → 调大: python3 stress_training.py --mem-mb $((MEM_MB - 200))"
    echo "    2. 系统有足够 swap，吸收了压力"
    echo "       → 加上 I/O 压力: 默认已开启，检查是否被 --no-io 关掉了"
    echo "    3. ssh_guardian 自身也被卡住了"
    echo "       → 检查 guardian stderr 日志"
fi

echo ""
