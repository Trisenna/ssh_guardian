#!/bin/bash
# launch_no_core.sh
# 确保训练进程不会生成 core dump（被 SIGKILL 后不写几十 GB 的 core 文件）
# 用法：./launch_no_core.sh python train.py [args...]

ulimit -c 0
exec "$@"
