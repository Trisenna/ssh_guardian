#!/bin/bash
# run_tests.sh
#
# ssh_guardian 自动化测试套件
#
# 测试内容：
#   1. 候选进程检测：能正确识别 allowlist 里的进程
#   2. 排除列表：不会碰 exclude 里的进程
#   3. 短暂失败不触发：失败次数不到阈值不杀
#   4. Stage 1 清杀：连续失败后杀掉最大的候选进程
#   5. Stage 2 清杀：Stage 1 后 SSH 仍失败则全杀
#   6. Dry-run 模式：只记录不真杀
#   7. 恢复后日志补写：紧急期间的日志在恢复后写入磁盘
#   8. 超时检测：SSH 命令卡住时能正确超时
#
# 用法: ./run_tests.sh
#
# 注意：此脚本会在 /tmp/sg_test_* 下创建临时文件，测试结束后自动清理。

set -euo pipefail

# ================================================================
# 颜色与工具函数
# ================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo -e "  ${GREEN}✓ PASS${NC}: $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo -e "  ${RED}✗ FAIL${NC}: $1"
    if [ -n "${2:-}" ]; then
        echo -e "         ${RED}原因: $2${NC}"
    fi
}

section() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
}

# ================================================================
# 路径设置
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARDIAN="$SCRIPT_DIR/../ssh_guardian"
GUARDIAN_SRC="$SCRIPT_DIR/../ssh_guardian.c"

# 测试临时目录
TEST_DIR="/tmp/sg_test_$$"
mkdir -p "$TEST_DIR"
mkdir -p "$TEST_DIR/bin"

# 控制文件和日志
FAKE_SSH_CONTROL="$TEST_DIR/fake_ssh_control"
FAKE_SSH_LOG="$TEST_DIR/fake_ssh.log"
SHM_LOG="$TEST_DIR/shm_guardian.log"
DISK_LOG="$TEST_DIR/disk_guardian.log"
GUARDIAN_STDERR="$TEST_DIR/guardian_stderr.log"

# 把 fake_ssh 放在 PATH 最前面
cp "$SCRIPT_DIR/fake_ssh.sh" "$TEST_DIR/bin/ssh"
chmod +x "$TEST_DIR/bin/ssh"

export FAKE_SSH_CONTROL
export FAKE_SSH_LOG
export PATH="$TEST_DIR/bin:$PATH"

# 编译 dummy_training 为 "python3"
DUMMY_PYTHON3="$TEST_DIR/bin/python3"

# ================================================================
# 清理函数
# ================================================================

cleanup() {
    # 杀掉所有测试残留进程
    pkill -f "$TEST_DIR" 2>/dev/null || true

    # 杀掉可能残留的 guardian
    if [ -n "${GUARDIAN_PID:-}" ] && kill -0 "$GUARDIAN_PID" 2>/dev/null; then
        kill "$GUARDIAN_PID" 2>/dev/null || true
        wait "$GUARDIAN_PID" 2>/dev/null || true
    fi

    # 杀掉可能残留的 dummy 进程
    for pf in "$TEST_DIR"/dummy_*.pid; do
        if [ -f "$pf" ]; then
            local dpid
            dpid=$(cat "$pf" 2>/dev/null) || true
            if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
                kill -9 "$dpid" 2>/dev/null || true
            fi
        fi
    done

    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ================================================================
# 编译
# ================================================================

section "编译"

echo "  编译 ssh_guardian..."
if gcc -O2 -o "$GUARDIAN" "$GUARDIAN_SRC" 2>"$TEST_DIR/compile_guardian.log"; then
    pass "ssh_guardian 编译成功"
else
    fail "ssh_guardian 编译失败" "$(cat "$TEST_DIR/compile_guardian.log")"
    exit 1
fi

echo "  编译 dummy_training → python3..."
if gcc -O2 -o "$DUMMY_PYTHON3" "$SCRIPT_DIR/dummy_training.c" 2>"$TEST_DIR/compile_dummy.log"; then
    pass "dummy_training 编译成功 (-> python3)"
else
    fail "dummy_training 编译失败" "$(cat "$TEST_DIR/compile_dummy.log")"
    exit 1
fi

# ================================================================
# 辅助函数
# ================================================================

set_ssh() {
    # set_ssh ok|fail|hang
    echo "$1" > "$FAKE_SSH_CONTROL"
}

start_dummy() {
    # start_dummy <tag> [alloc_mb]
    # 启动一个 dummy python3 进程，返回 pid
    local tag="$1"
    local mb="${2:-2}"
    local pidfile="$TEST_DIR/dummy_${tag}.pid"
    DUMMY_PIDFILE="$pidfile" "$DUMMY_PYTHON3" "$mb" > /dev/null 2>&1 &
    local dpid=$!
    # 等 pidfile 写出来
    for i in $(seq 1 20); do
        if [ -f "$pidfile" ]; then
            break
        fi
        sleep 0.1
    done
    echo "$dpid"
}

is_alive() {
    kill -0 "$1" 2>/dev/null
}

reset_test_env() {
    # 清理上一个测试的残留
    set_ssh ok
    rm -f "$SHM_LOG" "$DISK_LOG" "$FAKE_SSH_LOG" "$GUARDIAN_STDERR"
    rm -f "$TEST_DIR"/dummy_*.pid

    if [ -n "${GUARDIAN_PID:-}" ] && kill -0 "$GUARDIAN_PID" 2>/dev/null; then
        kill "$GUARDIAN_PID" 2>/dev/null
        wait "$GUARDIAN_PID" 2>/dev/null || true
    fi
    GUARDIAN_PID=""
}

start_guardian() {
    # start_guardian [extra_args...]
    "$GUARDIAN" \
        --interval 1 \
        --timeout 3 \
        --fail-threshold 2 \
        --cooldown 8 \
        --kill-count 1 \
        --min-rss-mb 1 \
        --recovery-wait 2 \
        --allow python3 \
        --exclude bash,zsh,sh,tmux,screen,sshd,ssh,login \
        --log-file "$DISK_LOG" \
        --shm-log "$SHM_LOG" \
        "$@" \
        2>"$GUARDIAN_STDERR" &
    GUARDIAN_PID=$!
    # 给 guardian 一点启动时间
    sleep 0.5
}

stop_guardian() {
    if [ -n "${GUARDIAN_PID:-}" ] && kill -0 "$GUARDIAN_PID" 2>/dev/null; then
        kill "$GUARDIAN_PID" 2>/dev/null
        wait "$GUARDIAN_PID" 2>/dev/null || true
    fi
    GUARDIAN_PID=""
}

log_contains() {
    # log_contains <file> <pattern>
    grep -q "$1" "$2" 2>/dev/null
}

# ================================================================
# 测试 1：SSH 正常时不杀任何东西
# ================================================================

section "测试 1：SSH 正常 → 不触发清杀"

reset_test_env
set_ssh ok

DUMMY_PID=$(start_dummy "t1" 2)
start_guardian

# 等几个检测周期
sleep 5

stop_guardian

if is_alive "$DUMMY_PID"; then
    pass "dummy 进程存活（未被误杀）"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    fail "dummy 进程被杀了" "SSH 正常时不应该杀任何东西"
fi

if [ -f "$SHM_LOG" ]; then
    if log_contains "TRIGGER" "$SHM_LOG"; then
        fail "日志中不应出现 TRIGGER"
    else
        pass "日志中无 TRIGGER 记录"
    fi
else
    fail "SHM 日志不存在"
fi

# ================================================================
# 测试 2：短暂失败（未达阈值）不触发
# ================================================================

section "测试 2：短暂 SSH 失败（1 次）→ 不触发清杀"

reset_test_env

DUMMY_PID=$(start_dummy "t2" 2)

# 先让 SSH 正常
set_ssh ok
start_guardian
sleep 2

# 失败 1 次
set_ssh fail
sleep 1.5

# 立即恢复
set_ssh ok
sleep 3

stop_guardian

if is_alive "$DUMMY_PID"; then
    pass "短暂失败后 dummy 进程存活"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    fail "短暂失败就把 dummy 杀了" "fail-threshold=2，只失败 1 次不该触发"
fi

# ================================================================
# 测试 3：连续失败 → Stage 1 清杀
# ================================================================

section "测试 3：连续 SSH 失败 → Stage 1 杀掉候选进程"

reset_test_env

DUMMY_PID=$(start_dummy "t3" 2)
echo "  dummy python3 pid=$DUMMY_PID"

# SSH 持续失败
set_ssh fail
start_guardian

# 等足够时间：fail-threshold=2, interval=1, 加上 recovery-wait=2
# 大约需要 2(失败积累) + 2(recovery_wait) + 2(余量) = 6 秒
sleep 8

stop_guardian

if is_alive "$DUMMY_PID"; then
    fail "dummy 进程仍然存活" "连续失败后应该被 Stage 1 杀掉"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    pass "dummy 进程已被杀掉"
fi

if [ -f "$SHM_LOG" ]; then
    if log_contains "STAGE1" "$SHM_LOG"; then
        pass "日志记录了 STAGE1 清杀"
    else
        fail "日志缺少 STAGE1 记录"
    fi

    if log_contains "KILL.*python3" "$SHM_LOG"; then
        pass "日志记录了杀掉 python3"
    else
        fail "日志缺少 python3 的 KILL 记录"
    fi
else
    fail "SHM 日志不存在"
fi

# ================================================================
# 测试 4：Stage 1 后 SSH 仍失败 → Stage 2 全杀
# ================================================================

section "测试 4：Stage 1 不够 → Stage 2 全杀"

reset_test_env

# 启动两个 dummy：一个大一个小
DUMMY_PID_BIG=$(start_dummy "t4big" 4)
DUMMY_PID_SMALL=$(start_dummy "t4small" 2)
echo "  dummy big pid=$DUMMY_PID_BIG (4MB), small pid=$DUMMY_PID_SMALL (2MB)"

# SSH 始终失败
set_ssh fail
start_guardian

# Stage1(2s积累+2s wait) + Stage2(2s wait) + 余量 = ~10s
sleep 12

stop_guardian

BIG_ALIVE=0
SMALL_ALIVE=0
is_alive "$DUMMY_PID_BIG" && BIG_ALIVE=1
is_alive "$DUMMY_PID_SMALL" && SMALL_ALIVE=1

if [ "$BIG_ALIVE" -eq 0 ] && [ "$SMALL_ALIVE" -eq 0 ]; then
    pass "两个 dummy 进程都被杀掉了"
else
    fail "还有 dummy 存活 (big=$BIG_ALIVE small=$SMALL_ALIVE)"
    kill -9 "$DUMMY_PID_BIG" 2>/dev/null || true
    kill -9 "$DUMMY_PID_SMALL" 2>/dev/null || true
fi

if [ -f "$SHM_LOG" ]; then
    if log_contains "STAGE2" "$SHM_LOG"; then
        pass "日志记录了 STAGE2 清杀"
    else
        fail "日志缺少 STAGE2 记录"
    fi
else
    fail "SHM 日志不存在"
fi

# ================================================================
# 测试 5：Dry-run 模式不真杀
# ================================================================

section "测试 5：--dry-run 模式只记录不杀"

reset_test_env

DUMMY_PID=$(start_dummy "t5" 2)
echo "  dummy python3 pid=$DUMMY_PID"

set_ssh fail
start_guardian --dry-run

sleep 8

stop_guardian

if is_alive "$DUMMY_PID"; then
    pass "dry-run 模式下 dummy 进程存活"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    fail "dry-run 模式下 dummy 被杀了" "不应该真的执行 kill"
fi

if [ -f "$SHM_LOG" ]; then
    if log_contains "DRY_RUN" "$SHM_LOG"; then
        pass "日志记录了 DRY_RUN 标记"
    else
        fail "日志缺少 DRY_RUN 记录"
    fi
else
    fail "SHM 日志不存在"
fi

# ================================================================
# 测试 6：排除列表——不碰 exclude 里的进程
# ================================================================

section "测试 6：排除列表生效"

reset_test_env

# 启动一个 python3 和一个 bash（通过 bash -c sleep）
DUMMY_PID=$(start_dummy "t6" 2)

# bash 子进程：用 bash 自己 sleep
bash -c 'echo $$ > '"$TEST_DIR"'/dummy_bash.pid; sleep 3600' &
BASH_PID=$!
sleep 0.3

echo "  dummy python3 pid=$DUMMY_PID, bash pid=$BASH_PID"

set_ssh fail
start_guardian

sleep 8

stop_guardian

# python3 应该被杀
if is_alive "$DUMMY_PID"; then
    fail "python3 应该被杀但还活着"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    pass "python3 被正确清杀"
fi

# bash 应该存活
if is_alive "$BASH_PID"; then
    pass "bash 进程存活（排除列表生效）"
    kill -9 "$BASH_PID" 2>/dev/null || true
else
    # bash 可能因为其他原因退出，检查是否被我们的 guardian 杀的
    if [ -f "$SHM_LOG" ] && grep -q "KILL.*pid=$BASH_PID" "$SHM_LOG"; then
        fail "bash 被 guardian 杀了" "排除列表没生效"
    else
        pass "bash 退出但不是 guardian 杀的（排除列表生效）"
    fi
fi

# ================================================================
# 测试 7：恢复后日志补写到磁盘
# ================================================================

section "测试 7：恢复后日志补写到磁盘"

reset_test_env

DUMMY_PID=$(start_dummy "t7" 2)

# 先让 SSH 失败触发清杀
set_ssh fail
start_guardian

# 等清杀发生（进入 emergency 模式，此时不写磁盘）
sleep 8

# 记录清杀前磁盘日志大小
DISK_SIZE_BEFORE=0
if [ -f "$DISK_LOG" ]; then
    DISK_SIZE_BEFORE=$(wc -c < "$DISK_LOG")
fi

# 让 SSH 恢复
set_ssh ok

# 等 cooldown 结束（8秒）+ guardian 检测到恢复并 flush
sleep 12

stop_guardian

# 检查磁盘日志是否增长了
if [ -f "$DISK_LOG" ]; then
    DISK_SIZE_AFTER=$(wc -c < "$DISK_LOG")
    if [ "$DISK_SIZE_AFTER" -gt "$DISK_SIZE_BEFORE" ]; then
        pass "恢复后磁盘日志有新内容写入"
    else
        fail "恢复后磁盘日志没有增长" "before=$DISK_SIZE_BEFORE after=$DISK_SIZE_AFTER"
    fi

    if log_contains "RECOVERY" "$DISK_LOG"; then
        pass "磁盘日志包含 RECOVERY 记录"
    else
        # RECOVERY 可能在 shm log 里
        if [ -f "$SHM_LOG" ] && log_contains "RECOVERY" "$SHM_LOG"; then
            pass "SHM 日志包含 RECOVERY 记录"
        else
            fail "找不到 RECOVERY 记录"
        fi
    fi

    if log_contains "emergency ring buffer flushed" "$DISK_LOG" || \
       log_contains "emergency ring buffer flushed" "$SHM_LOG" 2>/dev/null; then
        pass "日志确认了环形缓冲区已补写"
    else
        fail "找不到 flush 确认记录"
    fi
else
    fail "磁盘日志文件不存在"
fi

kill -9 "$DUMMY_PID" 2>/dev/null || true

# ================================================================
# 测试 8：SSH 超时检测
# ================================================================

section "测试 8：SSH 命令卡住 → 超时判定为失败"

reset_test_env

DUMMY_PID=$(start_dummy "t8" 2)

# 让 fake_ssh hang（模拟 sshd 卡住不响应）
set_ssh hang
start_guardian

# timeout=3, fail-threshold=2, 每次检测要等 3 秒超时
# 需要至少 3*2=6 秒 + recovery_wait=2 + 余量
sleep 14

stop_guardian

if is_alive "$DUMMY_PID"; then
    fail "超时场景下 dummy 应该被杀"
    kill -9 "$DUMMY_PID" 2>/dev/null || true
else
    pass "SSH 超时后正确触发清杀"
fi

if [ -f "$SHM_LOG" ] && log_contains "TRIGGER" "$SHM_LOG"; then
    pass "超时场景日志有 TRIGGER 记录"
else
    fail "超时场景缺少 TRIGGER 记录"
fi

# ================================================================
# 测试 9：Cooldown 期间不重复清杀
# ================================================================

section "测试 9：Cooldown 期间不杀新进程"

reset_test_env

# 先触发一轮清杀
DUMMY_PID1=$(start_dummy "t9a" 2)
set_ssh fail
start_guardian

sleep 8

# 第一个应该被杀了
if ! is_alive "$DUMMY_PID1"; then
    pass "第一轮 dummy 被正确清杀"
else
    fail "第一轮 dummy 没被杀"
    kill -9 "$DUMMY_PID1" 2>/dev/null || true
fi

# 现在处于 cooldown（8 秒），启动新的 dummy
DUMMY_PID2=$(start_dummy "t9b" 2)
echo "  新 dummy pid=$DUMMY_PID2，应该在 cooldown 期间不被杀"

# SSH 继续失败
sleep 4

stop_guardian

if is_alive "$DUMMY_PID2"; then
    pass "Cooldown 期间新 dummy 未被杀"
    kill -9 "$DUMMY_PID2" 2>/dev/null || true
else
    # 检查是不是 guardian 杀的
    if [ -f "$SHM_LOG" ] && grep -q "KILL.*pid=$DUMMY_PID2" "$SHM_LOG"; then
        fail "Cooldown 期间新 dummy 被 guardian 杀了"
    else
        pass "新 dummy 退出但不是 guardian 杀的"
    fi
fi

if [ -f "$SHM_LOG" ] && log_contains "COOLDOWN" "$SHM_LOG"; then
    pass "日志记录了 COOLDOWN 状态"
else
    fail "缺少 COOLDOWN 日志记录"
fi

# ================================================================
# 测试 10：日志内容完整性检查
# ================================================================

section "测试 10：日志内容完整性"

reset_test_env

DUMMY_PID=$(start_dummy "t10" 2)
set_ssh fail
start_guardian
sleep 8

set_ssh ok
sleep 5
stop_guardian
kill -9 "$DUMMY_PID" 2>/dev/null || true

# 检查日志里是否有所有关键字段
LOG_FILE="$SHM_LOG"
if [ -f "$LOG_FILE" ]; then
    CHECKS=0
    CHECKS_PASSED=0

    for keyword in "ssh_guardian started" "MemAvail=" "SSH_CHECK: FAILED" "TRIGGER" "SCAN:" "STAGE1" "KILL.*pid="; do
        CHECKS=$((CHECKS + 1))
        if grep -qE "$keyword" "$LOG_FILE"; then
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        else
            fail "日志缺少关键字段: $keyword"
        fi
    done

    if [ "$CHECKS" -eq "$CHECKS_PASSED" ]; then
        pass "日志包含所有关键字段 ($CHECKS_PASSED/$CHECKS)"
    fi
else
    fail "SHM 日志不存在"
fi

# ================================================================
# 结果汇总
# ================================================================

section "测试结果汇总"

echo ""
echo -e "  总测试: ${TOTAL_COUNT}"
echo -e "  ${GREEN}通过: ${PASS_COUNT}${NC}"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "  ${RED}失败: ${FAIL_COUNT}${NC}"
else
    echo -e "  失败: 0"
fi
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}有测试失败！请检查上面的详细信息。${NC}"
    echo ""
    echo "调试提示："
    echo "  查看 guardian stderr:  cat $GUARDIAN_STDERR"
    echo "  查看 SHM 日志:        cat $SHM_LOG"
    echo "  查看磁盘日志:         cat $DISK_LOG"
    echo "  查看 fake_ssh 调用:   cat $FAKE_SSH_LOG"
    exit 1
else
    echo -e "${GREEN}全部通过！ssh_guardian 工作正常。${NC}"
    exit 0
fi
