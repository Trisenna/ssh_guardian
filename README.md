# ssh_guardian — SSH 自动恢复守护进程

## 它是什么

你是否遇到过在共享服务器上跑训练，程序内存/IO 失控 → 整机卡死 → SSH 断开 → 所有人都连不上。

`ssh_guardian` 是一个跑在目标服务器上的 C 守护进程。它每隔几秒检测 SSH 是否还能正常工作，
一旦发现 SSH 连不上了，就自动杀掉你的训练进程，释放资源，恢复 SSH。

## 文件清单

```
ssh_guardian/
├── ssh_guardian.c          # 守护进程源码（C 语言，~800 行）
├── launch_no_core.sh       # 训练启动包装脚本（禁止 core dump）
├── stress_training.py      # 真实压力测试脚本（Python，模拟训练失控）
├── real_test.sh            # 一键真实环境端到端测试
├── test/
│   ├── run_tests.sh        # 自动化单元测试（10 个场景，23 项检查）
│   ├── fake_ssh.sh         # 测试用的假 ssh（可控成功/失败/超时）
│   └── dummy_training.c    # 测试用的假 python3 进程
└── README.md               # 本文件
```

## 工作原理

### 检测方式

每隔 N 秒执行一次：

```
ssh -o BatchMode=yes localhost /bin/true
```

这会走完整的 SSH 登录流程：TCP 连接 → 协议握手 → 密钥交换 → 公钥认证 → 执行命令。
链路上任何一环卡住（内存不够 fork、IO 卡住读不了密钥文件、sshd 被换出），都会超时失败。

**为什么用 localhost 而不是外部探测？**

你遇到的故障模式是"自己的训练把本机拖垮"。这种情况下 localhost SSH 一定也会挂，
而且 localhost 走 loopback 不受外部网络抖动影响，不会误杀。
如果故障原因是外部网络断了，localhost SSH 正常，不触发清杀——这是正确行为，
因为杀你的进程也修不了外部网络。

### 两级清杀

```
连续 N 次 SSH 失败
    ↓
Stage 1：杀 RSS 最大的 1 个候选进程
    ↓ 等待几秒，重新检测
    ↓ SSH 恢复 → 结束
    ↓ SSH 仍失败 ↓
Stage 2：杀掉所有候选进程
    ↓ 等待几秒，重新检测
    ↓ SSH 恢复 → 结束
    ↓ SSH 仍失败 → 停止动作（故障超出用户进程范围）
```

**候选进程** = 当前用户拥有的、进程名在 allowlist 里的（默认 python, python3）、
RSS 超过阈值的进程。

**绝不碰的进程** = bash, zsh, tmux, screen, sshd, ssh 等（exclude 列表）。

### 日志策略

| 时间段 | 磁盘日志 | /dev/shm 日志 | 内存环形缓冲区 |
|--------|---------|--------------|--------------|
| 平时正常 | ✅ 写 | ✅ 写 | ✅ 写 |
| SSH 失败，触发清杀 | ❌ 不写（避免加重 IO） | ✅ 写（tmpfs，走内存） | ✅ 写 |
| SSH 恢复 | ✅ 补写缓冲区内容 | ✅ 写 | ✅ 写 |

这样即使磁盘完全卡死，你事后也能通过 `/dev/shm` 日志看到发生了什么。
恢复后环形缓冲区会自动补写到磁盘日志，确保完整记录不丢失。


## 快速开始

### 第 1 步：编译

```bash
# 推荐静态编译
gcc -static -O2 -o ssh_guardian ssh_guardian.c

# 如果静态编译报错（缺少静态 libc），用动态编译
gcc -O2 -o ssh_guardian ssh_guardian.c
```

### 第 2 步：设置 localhost 公钥认证,注意这里是设置一个密钥用于本机的自我检查，所以直接在本机运行就可以。

```bash
# 如果还没有密钥对
ssh-keygen -t ed25519

# 把公钥加到自己的 authorized_keys
ssh-copy-id localhost

# 验证（不应该要求输密码）
ssh -o BatchMode=yes localhost /bin/true
echo $?   # 应输出 0
```

### 第 3 步：运行自动化测试

```bash
# 先跑单元测试，验证所有逻辑路径（不会影响系统，用假 SSH）
bash test/run_tests.sh
```

你应该看到 23/23 PASS。

### 第 4 步：Dry-run 观察

```bash
# 在 tmux 里运行，观察几天
./ssh_guardian --dry-run
```

看日志输出，确认它只会选中你的 python 进程，不会碰其他东西。

### 第 5 步：正式启用(或者在下面有用户级服务的方案)

```bash
# 在 tmux 里后台运行
./ssh_guardian
```

### 第 6 步：训练启动方式（这里主要是怕出现杀死进程后出现又要将信息写入磁盘导致磁盘依旧炸掉的情况，不用也行，maybe，至少在我的2G服务器上的实测他是给救回来了）

```bash
# 始终通过这个脚本启动训练，确保 core dump 被禁用
./launch_no_core.sh python3 train.py --epochs 100

# 或者手动
ulimit -c 0
python3 train.py
```


## 真实环境压力测试（2 核 2GB 服务器）

如果你想亲眼看到 ssh_guardian 在真实故障下救活 SSH，用这个：

### 方法 A：一键自动测试

```bash
bash real_test.sh
```

脚本会自动：编译 → 检查环境 → 启动 guardian → 启动压力脚本 → 等待清杀 → 分析日志 → 报告结果。

### 方法 B：手动分步测试

如果你想自己控制节奏，按以下步骤操作：

**终端 1（tmux 窗格 1）— 运行 guardian：**

```bash
ulimit -c 0
./ssh_guardian \
    --interval 3 \
    --fail-threshold 2 \
    --cooldown 60 \
    --min-rss-mb 100 \
    --recovery-wait 5 \
    --allow python3,python
```

**终端 2（tmux 窗格 2）— 启动压力测试：**

```bash
ulimit -c 0
python3 stress_training.py --mem-mb 1400 --io-workers 4
```

**终端 3（另一台机器）— 观察 SSH 连通性：**

```bash
# 每 2 秒尝试连一次，观察什么时候断、什么时候恢复
while true; do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes user@目标机 /bin/true 2>/dev/null; then
        echo "$(date): SSH OK"
    else
        echo "$(date): SSH FAIL"
    fi
    sleep 2
done
```

**预期结果：**

1. stress_training.py 启动后 30~60 秒，内存被吞满，系统开始卡
2. SSH 开始超时失败
3. ssh_guardian 检测到连续失败，触发 Stage 1，杀掉 stress 进程
4. 系统释放内存，SSH 在几秒内恢复
5. 你可以在 `/dev/shm/ssh_guardian.log` 和 `~/ssh_guardian.log` 看到完整记录

### stress_training.py 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--mem-mb N` | 1400 | 要吞的内存 MB 数（适合 2GB 服务器） |
| `--io-workers N` | 4 | I/O 并发 worker 数 |
| `--io-dir PATH` | /tmp/stress_io | I/O 临时文件目录 |
| `--no-io` | - | 只做内存压力，不做 I/O |
| `--no-mem` | - | 只做 I/O 压力，不做内存 |
| `--countdown N` | 10 | 启动前倒计时秒数 |

**安全措施：**
- 启动前有倒计时，给你时间取消
- 内置 15 分钟自毁定时器
- 退出时自动清理临时文件


## ssh_guardian 命令行参数

```
./ssh_guardian [选项]

--interval N        检测间隔秒数                         默认: 5
--timeout N         单次 SSH 超时秒数                     默认: 8
--fail-threshold N  连续失败多少次触发清杀                 默认: 3
--cooldown N        清杀后冷却秒数                        默认: 300
--kill-count N      Stage 1 杀几个                       默认: 1
--min-rss-mb N      候选进程最低 RSS (MB)                 默认: 512
--recovery-wait N   Stage 1 后等几秒再检测                默认: 15
--allow LIST        允许杀的进程名，逗号分隔               默认: python,python3
--exclude LIST      绝不杀的进程名，逗号分隔               默认: bash,zsh,sh,...
--log-file PATH     磁盘日志路径                          默认: ~/ssh_guardian.log
--shm-log PATH      /dev/shm 日志路径                    默认: /dev/shm/ssh_guardian.log
--dry-run           只检测记录，不真杀
--help              显示帮助
```


## 日志示例

正常运行时：

```
[2026-03-14 15:00:05] SSH_CHECK: OK
[2026-03-14 15:00:10] SSH_CHECK: OK
```

触发清杀：

```
[2026-03-14 15:01:15] SSH_CHECK: FAILED (1/3) | MemAvail=42MB SwapFree=0MB IoSome10=89.2 IoFull10=45.1
[2026-03-14 15:01:20] SSH_CHECK: FAILED (2/3) | MemAvail=38MB SwapFree=0MB IoSome10=92.1 IoFull10=51.3
[2026-03-14 15:01:25] SSH_CHECK: FAILED (3/3) | MemAvail=35MB SwapFree=0MB IoSome10=94.5 IoFull10=55.8
[2026-03-14 15:01:25] TRIGGER: 3 consecutive SSH failures, entering emergency mode
[2026-03-14 15:01:25] SCAN: found 2 candidate(s):
[2026-03-14 15:01:25]   [0] pid=12345 comm=python3 rss=24831MB state=D
[2026-03-14 15:01:25]   [1] pid=12350 comm=python3 rss=8192MB state=S
[2026-03-14 15:01:25] STAGE1: killing top 1 candidate(s)
[2026-03-14 15:01:25] KILL: pid=12345 comm=python3 rss=24831MB state=D result=OK
[2026-03-14 15:01:40] STAGE1: SSH recovered after killing 1 process(es)
```

恢复后补写：

```
[2026-03-14 15:01:45] RECOVERY: emergency ring buffer flushed to /home/user/ssh_guardian.log
[2026-03-14 15:01:45] RECOVERY: system recovered, disk logging resumed
```


## 已知限制

1. **不覆盖外部网络故障** — 如果 SSH 断开是因为入站网络问题，localhost SSH 正常，不会触发。这是正确行为。

2. **D 状态进程** — 处于不可中断磁盘等待的进程，SIGKILL 不会立即生效，要等内核从 I/O 等待返回。

3. **无 root 权限** — 守护进程以普通用户运行，只能杀自己的进程，无法使用 `mlockall`（受 `RLIMIT_MEMLOCK` 限制）。

4. **内核完全卡死** — 如果系统严重到内核调度都跑不动，任何用户态程序都无能为力。

5. **依赖 sshd** — 需要目标机上有运行中的 sshd，且当前用户可以公钥认证 localhost。


## 生产环境建议

```bash
# 推荐的生产参数（比测试更保守）
./ssh_guardian \
    --interval 5 \
    --fail-threshold 3 \
    --cooldown 300 \
    --min-rss-mb 1024 \
    --recovery-wait 15 \
    --allow python,python3
```

如果你的系统支持 systemd user service：

```bash
mkdir -p ~/.config/systemd/user
```

创建 `~/.config/systemd/user/ssh-guardian.service`：

```ini
[Unit]
Description=SSH Guardian

[Service]
ExecStart=%h/ssh_guardian --interval 5 --fail-threshold 3 --cooldown 300
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now ssh-guardian
systemctl --user status ssh-guardian
```
