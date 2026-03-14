# ssh_guardian — 训练炸了？SSH 自动恢复

## 这东西解决什么问题？

你在一台共享服务器上跑深度学习训练，结果程序内存或磁盘 I/O 失控，
整台服务器卡死了，SSH 连不上，所有人都被你影响了，你也进不去杀进程。

**ssh_guardian 就是你提前放在服务器上的一个"保险丝"。**

它会一直在后台悄悄运行，每隔几秒自动检查 SSH 还能不能用。
一旦发现 SSH 挂了，它就自动帮你杀掉训练进程，把服务器救回来。

**不需要 root 权限，不需要安装任何软件，不需要 sudo。**
只要服务器上有 `gcc` 和 `sshd` 在运行（你能 SSH 登录就说明有），就能用。

---

## 文件清单

```
ssh_guardian.c          ← 守护进程源码
launch_no_core.sh       ← 训练启动辅助脚本
stress_training.py      ← 压力测试脚本（测试用）
real_test.sh            ← 一键端到端测试（测试用）
test/
├── run_tests.sh        ← 自动化单元测试（10 个场景，23 项检查）
├── fake_ssh.sh         ← 测试用的假 ssh
└── dummy_training.c    ← 测试用的假 python3 进程
README.md               ← 你正在看的这个文件
```

---

## 从零开始，一步一步跟着做

下面的所有命令都是**在服务器上执行**的。

### 第 0 步：上传并解压

把 `ssh_guardian.tar.gz` 上传到服务器，然后：

```bash
tar xzf ssh_guardian.tar.gz
ls
```

你应该能看到 `ssh_guardian.c`、`README.md` 等文件。

---

### 第 1 步：编译

```bash
gcc -O2 -o ssh_guardian ssh_guardian.c
```

成功的话不会有任何输出，当前目录会多一个 `ssh_guardian` 可执行文件。

**如果报错 `gcc: command not found`：**

服务器上没有 gcc 编译器，你又没有权限装。两个解决办法：

办法一：看看服务器上有没有别的版本

```bash
which cc
which gcc-11
which gcc-12
```

如果有，比如 `gcc-12`，就把命令里的 `gcc` 换成 `gcc-12`。

办法二：在你自己电脑上编译好，传上去

```bash
# 在你自己的 Linux 电脑/虚拟机上执行
gcc -static -O2 -o ssh_guardian ssh_guardian.c
# 然后 scp 传到服务器
scp ssh_guardian 你的用户名@服务器地址:~/
```

静态编译（`-static`）生成的文件不依赖任何库，直接能跑。

---

### 第 2 步：让服务器能"自己 SSH 自己"

ssh_guardian 的检测方式是让服务器自己 SSH 自己（`ssh localhost`）。
这需要一个**本机的免密登录**，全部在服务器上操作，跟你本地电脑无关，不需要任何权限。

**为什么需要这个？**
ssh_guardian 是自动运行的程序，没有人帮它输密码，所以需要免密码登录 localhost。

```bash
# 生成密钥对（一路回车，不要设密码）
ssh-keygen -t ed25519
```

你会看到这样的提示：

```
Enter file in which to save the key (/home/xxx/.ssh/id_ed25519):    ← 直接回车
Enter passphrase (empty for no passphrase):                         ← 直接回车
Enter same passphrase again:                                        ← 直接回车
```

如果提示文件已存在、是否覆盖，选 `n`，说明你以前生成过，直接用旧的就行。

```bash
# 把公钥加到自己的 authorized_keys
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

```bash
# 验证（不应该要求输密码）
ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost /bin/true
echo $?
```

**输出 `0`** → 成功了，继续下一步。

**输出不是 `0`** → 最常见的原因是权限不对，再执行一遍：

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chmod 600 ~/.ssh/id_ed25519
```

然后重新验证。如果还是不行，把报错信息发给我。

---

### 第 3 步：跑一遍自动化测试（推荐）

这步用假的 SSH 测试 ssh_guardian 的所有功能，**不会对系统造成任何影响**。

```bash
bash test/run_tests.sh
```

最后应该看到：

```
  总测试: 23
  通过: 23
  失败: 0

  全部通过！ssh_guardian 工作正常。
```

---

### 第 4 步：后台运行 ssh_guardian

你需要让 ssh_guardian 在后台持续运行，**关掉 SSH 窗口也不能停**。

**用 `nohup`**（所有 Linux 系统都自带，不需要装任何东西）：

```bash
nohup ./ssh_guardian > /dev/null 2>&1 &
echo $!
```

第二行会输出一个数字，那是 ssh_guardian 的进程号（PID），记一下。

验证它在运行：

```bash
ps aux | grep ssh_guardian
```

以后想停掉它：

```bash
kill 刚才记下的PID
# 或者
pkill ssh_guardian
```

想看日志：

```bash
# 实时看最新日志
tail -f ~/ssh_guardian.log

# 看内存文件系统里的日志（系统卡死期间也能记录）
cat /dev/shm/ssh_guardian.log
```

**如果你的服务器上有 tmux 或 screen**（很多服务器预装了），也可以用：

```bash
# 用 tmux
tmux new -s guardian
./ssh_guardian
# 按 Ctrl+B 松手再按 D 脱离，以后 tmux attach -t guardian 接回来

# 或者用 screen
screen -S guardian
./ssh_guardian
# 按 Ctrl+A 松手再按 D 脱离，以后 screen -r guardian 接回来
```

不知道有没有？试一下就知道了：

```bash
which tmux    # 有输出就是有
which screen  # 有输出就是有
```

**三种方式都行，`nohup` 是保底方案，一定能用。**

---

### 第 5 步：搞定！日常使用

ssh_guardian 现在已经在保护你的服务器了。

**启动训练时**，建议加一行 `ulimit -c 0`：

```bash
ulimit -c 0
python3 train.py
```

或者用附带的脚本（效果一样）：

```bash
bash launch_no_core.sh python3 train.py
```

**为什么要 `ulimit -c 0`？**
程序被强杀时，系统可能生成一个 core dump 文件（把内存内容写到磁盘）。
如果你的训练占了 30GB 内存，core dump 就是 30GB，写磁盘又会把系统搞炸。
这行命令禁止生成 core dump。

---

## 亲眼验证它能救——真实压力测试

> ⚠️ **以下测试会让服务器暂时变得非常卡！**
> 只在测试专用服务器上跑，别在别人正在用的共享服务器上跑。

### 方法 A：一键测试

```bash
bash real_test.sh
```

它会自动完成一切：编译 → 环境检查 → 启动 guardian → 制造压力 → 等待自动恢复 → 分析结果。

### 方法 B：手动测试（推荐，能看到完整过程）

开三个 SSH 窗口连到服务器（或者用 tmux/screen 分三个窗格）。

**窗口 1 — 启动 ssh_guardian：**

```bash
./ssh_guardian \
    --interval 3 \
    --fail-threshold 2 \
    --cooldown 60 \
    --min-rss-mb 100 \
    --recovery-wait 5 \
    --allow python3,python
```

**窗口 2 — 制造故障：**

```bash
ulimit -c 0
python3 stress_training.py --mem-mb 1200 --io-workers 4 --countdown 5
```

这个脚本会疯狂吞内存和写磁盘，让服务器卡死。它有 5 秒倒计时和 15 分钟自毁定时器。

**窗口 3（在你自己的电脑上）— 观察 SSH 状态：**

```bash
while true; do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes 你的用户名@服务器地址 /bin/true 2>/dev/null; then
        echo "$(date): SSH 正常 ✓"
    else
        echo "$(date): SSH 断了 ✗"
    fi
    sleep 2
done
```

**你会看到这样的过程：**

```
14:00:30: SSH 正常 ✓
14:00:32: SSH 正常 ✓         ← 压力开始上升
14:00:34: SSH 断了 ✗         ← 系统卡住了
14:00:36: SSH 断了 ✗
14:00:38: SSH 断了 ✗         ← ssh_guardian 检测到并杀掉进程
14:00:40: SSH 正常 ✓         ← 恢复了！
```

---

## 参数说明

```
./ssh_guardian [选项]

检测相关：
  --interval N        每隔几秒检测一次 SSH           默认: 5
  --timeout N         单次检测超时秒数               默认: 8
  --fail-threshold N  连续失败几次才动手             默认: 3

清杀相关：
  --kill-count N      第一轮先杀几个                 默认: 1
  --min-rss-mb N      只杀内存占用超过 N MB 的进程    默认: 512
  --recovery-wait N   杀完后等几秒再检查是否恢复      默认: 15
  --cooldown N        动手后冷静几秒不再动手          默认: 300

进程过滤：
  --allow LIST        允许杀的进程名（逗号分隔）      默认: python,python3
  --exclude LIST      绝不能杀的进程名（逗号分隔）    默认: bash,zsh,sh,tmux,screen,sshd...

日志：
  --log-file PATH     磁盘日志路径                   默认: ~/ssh_guardian.log
  --shm-log PATH      内存日志路径                   默认: /dev/shm/ssh_guardian.log

其他：
  --dry-run           只检测和记录，不真的杀进程（用于先观察）
  --help              显示帮助
```

**参数建议：**

| 场景         | 建议                                                         |
| ------------ | ------------------------------------------------------------ |
| 日常使用     | 直接 `./ssh_guardian`，默认参数就行                          |
| 想先观察几天 | 加 `--dry-run`，确认没问题再去掉                             |
| 测试验证     | `--interval 3 --fail-threshold 2 --cooldown 60 --min-rss-mb 100` |

---

## 工作原理简述

**检测**：让服务器自己 `ssh localhost /bin/true`。
这会走完整的 SSH 登录流程，系统资源耗尽时任何环节都会卡住超时。
走 localhost 不经过外部网络，外部断网不会误杀你的程序。

**两级清杀**：先杀占内存最大的一个训练进程，等一会看 SSH 是否恢复；
如果没恢复，再把所有训练进程全杀掉。只杀你自己的进程，不碰别人的。

**日志**：平时正常写磁盘。系统卡死时停止写磁盘（避免雪上加霜），
改写 `/dev/shm`（内存文件系统，不走磁盘）。恢复后自动把遗漏的日志补写到磁盘。

---

## 常见问题

**Q: 我平时用密码登录 SSH，需要改成密钥登录吗？**
A: 不需要。你平时怎么登录不用改。第 2 步配的是"服务器自己 SSH 自己"的免密登录，跟你怎么连服务器无关。

**Q: 服务器重启后 ssh_guardian 还在吗？**
A: 不在，需要你重新执行 `nohup ./ssh_guardian > /dev/null 2>&1 &`。
如果你想重启自动运行，可以把这行命令加到 `~/.bashrc` 的末尾：

```bash
# 加到 ~/.bashrc 末尾（只在还没运行时才启动，避免重复）
pgrep -x ssh_guardian > /dev/null || nohup ~/ssh_guardian > /dev/null 2>&1 &
```

这样每次你 SSH 登录时，如果 guardian 没在跑，就会自动启动。

**Q: 会不会误杀我正在跑的训练？**
A: 只有 SSH 真的连不上才会动手。先加 `--dry-run` 跑几天观察。

**Q: 会不会杀掉别人的进程？**
A: 不会。只杀你自己用户名下的、且在 `--allow` 列表里的进程（默认是 python 和 python3）。

**Q: 我想保护的不只是 python 进程怎么办？**
A: 用 `--allow` 指定，比如 `--allow python3,java,myapp`。

**Q: 我不想让 jupyter 被杀怎么办？**
A: 默认的排除列表已经包含 `jupyter-lab` 和 `jupyter-notebook`。如果你有其他要保护的，用 `--exclude` 追加。

**Q: 没有 gcc 怎么办？**
A: 在你自己的电脑上 `gcc -static -O2 -o ssh_guardian ssh_guardian.c`，然后把生成的 `ssh_guardian` 文件传到服务器上，直接就能用。

**Q: 没有 tmux 也没有 screen 怎么办？**
A: 用 `nohup`，第 4 步里写了，所有 Linux 都自带。

---

## 已知限制

1. **外部网络断了不会触发** — localhost SSH 正常就不动手。这是对的，杀你的程序也修不了外部网络。

2. **内核彻底卡死** — 如果系统卡到 guardian 自己也跑不了，谁也没办法。但这种情况极少，guardian 本身只有几十 KB，优先级很高。

3. **D 状态进程** — 有些进程卡在磁盘 I/O 上，即使 SIGKILL 也不会立即死，要等内核处理完。

4. **需要 sshd 在运行** — 你能 SSH 连上服务器就说明有，不需要额外操作。