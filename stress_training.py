#!/usr/bin/env python3
"""
stress_training.py — 模拟深度学习训练进程失控

在 2 核 2GB 服务器上，此脚本会：
  阶段 1：逐步吞掉大部分内存（触发 swap 风暴）
  阶段 2：同时制造高强度随机磁盘 I/O（触发 I/O 阻塞）
  阶段 3：保持压力，等待被 ssh_guardian 杀掉

用法：
  ulimit -c 0
  python3 stress_training.py [--mem-mb 1400] [--io-workers 4] [--io-dir /tmp/stress_io]

安全措施：
  - 脚本启动后会打印 PID 和倒计时，给你 10 秒时间 Ctrl+C 取消
  - 内置 15 分钟自毁定时器，防止忘记清理
  - 所有临时文件在退出时自动删除
"""

import os
import sys
import time
import signal
import argparse
import threading
import tempfile
import shutil
import mmap
import random

# ========================================
# 全局状态
# ========================================

stress_chunks = []       # 内存块列表
io_dir = None            # I/O 临时目录
stop_event = threading.Event()

# ========================================
# 自毁定时器
# ========================================

MAX_LIFETIME = 15 * 60  # 15 分钟后自杀，防止遗忘

def self_destruct_timer():
    """安全网：超时后自动退出"""
    start = time.time()
    while not stop_event.is_set():
        elapsed = time.time() - start
        if elapsed >= MAX_LIFETIME:
            print(f"\n[stress] 已运行 {MAX_LIFETIME}s，自毁定时器触发，自动退出", flush=True)
            os.kill(os.getpid(), signal.SIGTERM)
            return
        stop_event.wait(timeout=5)

# ========================================
# 内存压力
# ========================================

def eat_memory(target_mb, chunk_mb=50):
    """
    逐步分配内存并写满，确保进入 RSS。
    每次分配 chunk_mb MB，间隔 2 秒，让你能观察系统变化。
    """
    allocated = 0
    print(f"[stress] 开始分配内存，目标 {target_mb} MB，每次 {chunk_mb} MB", flush=True)

    while allocated < target_mb and not stop_event.is_set():
        remaining = target_mb - allocated
        this_chunk = min(chunk_mb, remaining)
        size = this_chunk * 1024 * 1024

        try:
            buf = bytearray(size)
            # 逐页写入随机数据，确保物理页被分配（不会被内核合并为零页）
            for offset in range(0, size, 4096):
                buf[offset] = random.randint(0, 255)
            stress_chunks.append(buf)
            allocated += this_chunk
            print(f"[stress] 已分配 {allocated}/{target_mb} MB (RSS 应接近此值)", flush=True)
        except MemoryError:
            print(f"[stress] MemoryError at {allocated} MB, 停止分配", flush=True)
            break

        time.sleep(2)

    print(f"[stress] 内存分配完成: {allocated} MB", flush=True)
    return allocated

# ========================================
# I/O 压力
# ========================================

def io_worker(worker_id, io_path):
    """
    单个 I/O worker：反复创建、写入、sync、读取、删除文件。
    每个文件 8-32MB 随机大小，制造大量随机 I/O。
    """
    count = 0
    while not stop_event.is_set():
        try:
            fname = os.path.join(io_path, f"worker{worker_id}_{count}.bin")
            size = random.randint(8, 32) * 1024 * 1024  # 8-32 MB

            # 写
            with open(fname, 'wb') as f:
                # 分块写入，每块 1MB
                written = 0
                while written < size and not stop_event.is_set():
                    chunk = min(1024 * 1024, size - written)
                    f.write(os.urandom(chunk))
                    written += chunk
                f.flush()
                os.fsync(f.fileno())

            if stop_event.is_set():
                break

            # 读回来（制造读 I/O）
            with open(fname, 'rb') as f:
                while True:
                    block = f.read(1024 * 1024)
                    if not block:
                        break

            # 删除后重来
            os.unlink(fname)
            count += 1

        except (IOError, OSError) as e:
            print(f"[stress] io_worker {worker_id}: {e}", flush=True)
            time.sleep(1)

def start_io_stress(io_path, num_workers):
    """启动多个 I/O worker 线程"""
    print(f"[stress] 启动 {num_workers} 个 I/O worker，目录: {io_path}", flush=True)
    os.makedirs(io_path, exist_ok=True)

    threads = []
    for i in range(num_workers):
        t = threading.Thread(target=io_worker, args=(i, io_path), daemon=True)
        t.start()
        threads.append(t)

    return threads

# ========================================
# 清理
# ========================================

def cleanup(signum=None, frame=None):
    """清理所有资源"""
    stop_event.set()
    print(f"\n[stress] 正在清理...", flush=True)

    # 释放内存
    stress_chunks.clear()

    # 删除临时 I/O 目录
    if io_dir and os.path.exists(io_dir):
        try:
            shutil.rmtree(io_dir, ignore_errors=True)
            print(f"[stress] 已删除临时目录 {io_dir}", flush=True)
        except Exception:
            pass

    if signum is not None:
        sys.exit(1)

# ========================================
# 主流程
# ========================================

def main():
    global io_dir

    parser = argparse.ArgumentParser(
        description="模拟训练进程失控，用于测试 ssh_guardian"
    )
    parser.add_argument("--mem-mb", type=int, default=1400,
                        help="要吞掉的内存 MB 数 (默认: 1400，适合 2GB 服务器)")
    parser.add_argument("--io-workers", type=int, default=4,
                        help="I/O 并发 worker 数 (默认: 4)")
    parser.add_argument("--io-dir", type=str, default="/tmp/stress_io",
                        help="I/O 临时文件目录 (默认: /tmp/stress_io)")
    parser.add_argument("--chunk-mb", type=int, default=50,
                        help="每次分配的内存块大小 MB (默认: 50)")
    parser.add_argument("--no-io", action="store_true",
                        help="只做内存压力，不做 I/O 压力")
    parser.add_argument("--no-mem", action="store_true",
                        help="只做 I/O 压力，不做内存压力")
    parser.add_argument("--countdown", type=int, default=10,
                        help="启动前倒计时秒数 (默认: 10)")

    args = parser.parse_args()
    io_dir = args.io_dir

    # 注册信号处理
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    print("=" * 60, flush=True)
    print("  stress_training.py — ssh_guardian 真实环境测试", flush=True)
    print("=" * 60, flush=True)
    print(f"  PID:        {os.getpid()}", flush=True)
    print(f"  目标内存:   {args.mem_mb} MB" if not args.no_mem else "  内存压力:   关闭", flush=True)
    print(f"  I/O worker: {args.io_workers}" if not args.no_io else "  I/O 压力:   关闭", flush=True)
    print(f"  I/O 目录:   {args.io_dir}" if not args.no_io else "", flush=True)
    print(f"  自毁定时:   {MAX_LIFETIME // 60} 分钟", flush=True)
    print(f"  进程名:     python3 (会被 ssh_guardian 识别)", flush=True)
    print("=" * 60, flush=True)

    # 倒计时
    print(f"\n  ⚠️  {args.countdown} 秒后开始施压，Ctrl+C 可取消\n", flush=True)
    for i in range(args.countdown, 0, -1):
        print(f"  {i}...", flush=True)
        time.sleep(1)
    print("  开始！\n", flush=True)

    # 启动自毁定时器
    timer_thread = threading.Thread(target=self_destruct_timer, daemon=True)
    timer_thread.start()

    # 阶段 1：内存压力
    if not args.no_mem:
        print("[阶段 1] 开始吞内存...", flush=True)
        actual_mb = eat_memory(args.mem_mb, args.chunk_mb)
        print(f"[阶段 1] 完成，实际占用 {actual_mb} MB\n", flush=True)
        time.sleep(3)
    else:
        print("[阶段 1] 跳过（--no-mem）\n", flush=True)

    # 阶段 2：I/O 压力
    if not args.no_io:
        print("[阶段 2] 开始 I/O 风暴...", flush=True)
        io_threads = start_io_stress(args.io_dir, args.io_workers)
        print(f"[阶段 2] {len(io_threads)} 个 I/O worker 已启动\n", flush=True)
    else:
        print("[阶段 2] 跳过（--no-io）\n", flush=True)

    # 阶段 3：保持压力，等待被杀
    print("[阶段 3] 压力维持中，等待 ssh_guardian 介入...", flush=True)
    print("         如果 ssh_guardian 正常工作，此进程会被 SIGKILL", flush=True)
    print("         你可以从另一台机器观察 SSH 是否先断后恢复", flush=True)
    print("         Ctrl+C 可手动终止\n", flush=True)

    try:
        tick = 0
        while not stop_event.is_set():
            time.sleep(10)
            tick += 10
            # 每 10 秒报告一次状态
            try:
                with open(f"/proc/{os.getpid()}/status") as f:
                    status = f.read()
                for line in status.split('\n'):
                    if line.startswith('VmRSS:'):
                        rss = line.split()[1]
                        print(f"[stress] +{tick}s | RSS={rss} kB | 仍在运行...", flush=True)
                        break
            except Exception:
                print(f"[stress] +{tick}s | 仍在运行...", flush=True)

    except KeyboardInterrupt:
        pass
    finally:
        cleanup()

if __name__ == "__main__":
    main()
