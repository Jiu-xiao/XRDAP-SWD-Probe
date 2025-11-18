$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# 工具检查
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) { throw "找不到 iverilog.exe（请加入 PATH）" }
if (-not (Get-Command vvp      -ErrorAction SilentlyContinue)) { throw "找不到 vvp.exe（请加入 PATH）" }

# 输出目录
New-Item -ItemType Directory -Force -Path build | Out-Null

# 公共源文件
$src = @('swd-probe.v')

Write-Host "=== [READ] 编译 ==="
& iverilog -g2012 -Wall -s testbench_read  -o build/sim_read.vvp  $src 'testbench_read.v'
Write-Host "=== [READ] 运行 ==="
& vvp build/sim_read.vvp

Write-Host "=== [WRITE] 编译 ==="
& iverilog -g2012 -Wall -s testbench_write -o build/sim_write.vvp $src 'testbench_write.v'
Write-Host "=== [WRITE] 运行 ==="
& vvp build/sim_write.vvp

Write-Host "=== [SPECIAL] 编译 ==="
& iverilog -g2012 -Wall -s testbench_special -o build/sim_special.vvp $src 'testbench_special.v'

$plus = if ($args -contains 'force_drive0') { '+force_drive0' } else { '' }
Write-Host "=== [SPECIAL] 运行 $plus ==="
& vvp build/sim_special.vvp $plus

Write-Host "`n==== ALL PASS ===="

# === [PLOT] 生成 PNG 波形图（需要已安装 Python 和 vcdvcd:  pip install vcdvcd matplotlib） ===
# 选择 python 解释器
$py = $null
if (Get-Command python -ErrorAction SilentlyContinue) { $py = "python" }
elseif (Get-Command py -ErrorAction SilentlyContinue) { $py = "py -3" }
else { Write-Warning "找不到 python，可用 winget / 官网安装后再运行：pip install vcdvcd matplotlib" }

if ($py) {
    Write-Host "=== [PLOT] swd_read.vcd → READ 模式，三视角 ==="
    & $py .\vcd_to_png.py --glob "swd_read.vcd"    --view all --mode read

    Write-Host "=== [PLOT] swd_write.vcd → WRITE 模式，三视角 ==="
    & $py .\vcd_to_png.py --glob "swd_write.vcd"   --view all --mode write

    Write-Host "=== [PLOT] swd_special.vcd → 自动判定（混合帧），三视角 ==="
    & $py .\vcd_to_png.py --glob "swd_special.vcd" --view all --mode auto
}
