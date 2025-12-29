#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 工具检查
if ! command -v iverilog >/dev/null 2>&1; then
  echo "找不到 iverilog（请加入 PATH）" >&2
  exit 1
fi
if ! command -v vvp >/dev/null 2>&1; then
  echo "找不到 vvp（请加入 PATH）" >&2
  exit 1
fi

# 输出目录
mkdir -p build

# 公共源文件
SRC=("swd-probe.v")

echo "=== [READ] 编译 ==="
iverilog -g2012 -Wall -s testbench_read  -o build/sim_read.vvp  "${SRC[@]}" testbench_read.v
echo "=== [READ] 运行 ==="
vvp build/sim_read.vvp

echo "=== [WRITE] 编译 ==="
iverilog -g2012 -Wall -s testbench_write -o build/sim_write.vvp "${SRC[@]}" testbench_write.v
echo "=== [WRITE] 运行 ==="
vvp build/sim_write.vvp

echo "=== [SPECIAL] 编译 ==="
iverilog -g2012 -Wall -s testbench_special -o build/sim_special.vvp "${SRC[@]}" testbench_special.v

# 兼容 PowerShell 版本的可选参数：force_drive0 -> vvp +force_drive0
plus=""
for arg in "$@"; do
  if [[ "$arg" == "force_drive0" ]]; then
    plus="+force_drive0"
    break
  fi
done

echo "=== [SPECIAL] 运行 ${plus} ==="
vvp build/sim_special.vvp ${plus}

# 可选：生成 PNG（若检测到 python 且本目录存在 vcd_to_png.py）
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY="python3"
elif command -v python >/dev/null 2>&1; then
  PY="python"
fi

if [[ -n "$PY" && -f "./vcd_to_png.py" ]]; then
  echo "=== [PLOT] swd_*.vcd → raw + frames(zones) ==="
  "$PY" ./vcd_to_png.py --glob "swd_*.vcd" --default --mode auto || true

  echo
  echo "输出目录："
  echo "  - vcd_png/raw/    （整段 RAW 波形）"
  echo "  - vcd_png/frames/ （识别到帧后输出 *_ZONES.png）"
else
  echo "提示：未检测到可用的 Python 或 vcd_to_png.py，跳过 PNG 生成。" >&2
  echo "如需生成图：pip install vcdvcd matplotlib" >&2
fi

echo
echo "==== ALL PASS ===="
