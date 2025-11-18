# vcd_to_png.py — 一帧一图（READ/WRITE/auto），或自动降级 RAW；主机/从机/总线视角；按位采样 + 区块着色 + 每帧摘要
from pathlib import Path
import argparse
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from vcdvcd import VCDVCD

# ===================== 可调参数（与 TB/README 对齐） =====================
PARITY_MODE = "TB"     # "TB": parity = ^data（与你 TB/README 一致）；"SWD": 规范奇校验（READ 为奇校验=~^data）
TRACK_AMP   = 0.85     # 单轨振幅（0/1 映射到 0..TRACK_AMP；Z=0.2*AMP；X=0.7*AMP）
TRACK_STEP  = 1.6      # 相邻轨道步距（避免重叠）
LW          = 1.2      # 波形线宽
FONTSZ_MAIN = 11
FONTSZ_LAB  = 9
FONTSZ_TINY = 8

DEFAULT_VIEW = "all"   # 'host' / 'target' / 'bus' / 'all'
DEFAULT_MODE = "auto"  # 'read' / 'write' / 'auto'（auto 识别不到帧则降级为 RAW 长图）

# 关键信号后缀（后缀匹配；推荐用 --map 精确指定）
CORE_SUFFIX = [".sck", ".rst_n", ".rnw", ".mosi", ".miso", ".swdio"]
# 主机输出使能（低有效，0=驱动，1=释放）
OE_CANDIDATES = [".swdio_oe_n_fix", ".host_oe_n", ".oe_n"]

# 区块颜色
ZONE_CLR = dict(PAD="#cfe9ff", REQ="#cfe9ff", TA1="#ffd8a8", ACK="#ffb3b3",
                TA2="#ffd8a8", DATA="#cfe9ff", PAR="#d6ffd6")

BIT_TICKS = (0, 8, 16, 24, 32, 40, 46)

# ===================== 工具函数 =====================
def rise_edges(tv):
    """把 x/z→1 也当上升沿，避免丢第一拍"""
    tv = sorted(tv, key=lambda x: x[0])
    edges, last = [], None
    for t, v in tv:
        if v == '1' and last != '1':
            edges.append(t)
        last = v
    return edges

def value_at(tv, ts):
    last = '0'
    for t, v in sorted(tv, key=lambda x: x[0]):
        if t > ts: break
        last = v
    return last

def decode_bits_at(edges, tv, b_lo, b_hi):
    """按位采样：在相邻两个 SCK 上升沿的中点采样"""
    bits = []
    for i in range(b_lo, b_hi):
        if i+1 >= len(edges): break
        tm = (edges[i] + edges[i+1]) // 2
        bits.append(value_at(tv, tm))
    return bits

def bits_lsb_first_to_int(bit_list):
    if not bit_list or any(b not in ('0','1') for b in bit_list): return 0, False
    v = 0
    for i, b in enumerate(bit_list):
        if b == '1': v |= (1 << i)
    return v, True

def parity_expected_32(v):
    xor1 = bin(v & 0xFFFFFFFF).count("1") & 1
    return xor1 if PARITY_MODE == "TB" else (1 - xor1)

def build_ref_to_tv(v):
    """统一 fullname -> tv 的索引，兼容不同 VCD 结构"""
    ref_to_tv = {}
    data = getattr(v, "data", {})
    for node in data.values():
        tv = getattr(node, "tv", [])
        if not tv: continue
        refs = getattr(node, "references", [])
        if refs:
            for r in refs: ref_to_tv[str(r)] = tv
            continue
        nets = getattr(node, "nets", [])
        for net in nets:
            hier = str(getattr(net, "hier", "")).strip(".")
            name = str(getattr(net, "name", "")).strip(".")
            full = (hier + "." + name).strip(".")
            if full: ref_to_tv[full] = tv
    return ref_to_tv

def pick_by_suffix(ref_to_tv, suf):
    for full in ref_to_tv.keys():
        if full.endswith(suf): return full
    return ""

def tv_to_step(tv, t_end=None):
    """把 0/1/z/x 转为阶梯线；z=0.2*AMP, x=0.7*AMP。若给出 t_end，则把最后电平延长到 t_end。"""
    if not tv: return [], []
    tv = sorted(tv, key=lambda x: x[0])
    t, y = [tv[0][0]], [tv[0][1]]; last = tv[0][1]
    for ti, vi in tv[1:]:
        t += [ti, ti]; y += [last, vi]; last = vi
    # 原来是 t.append(t[-1] + 1)
    end = (t_end if (t_end is not None) else (t[-1] + 1))
    if end > t[-1]:
        t.append(end); y.append(last)
    y = [0.0 if v=='0' else TRACK_AMP if v=='1'
         else 0.20*TRACK_AMP if v in ('z','Z')
         else 0.70*TRACK_AMP for v in y]
    return t, y

def merge_time_axis(tv_a, tv_b):
    return sorted(set([t for t,_ in tv_a] + [t for t,_ in tv_b]))

def count_edges_in_range(tv, t0, t1):
    last = None; cnt = 0
    for t, v in sorted(tv, key=lambda x: x[0]):
        if t < t0: 
            last = v; 
            continue
        if t > t1: 
            break
        if last is not None and v != last:
            cnt += 1
        last = v
    return cnt

def derive_host_tv(tv_bus, tv_mosi, tv_oe_n, fedges=None, rnw='x', ack_ok=None):
    """
    主机视角：OE=1 -> Z；OE=0 -> 主机输出（优先 MOSI；没有 MOSI 则用 bus）。
    若无 tv_oe_n，则按窗口推断：0..9 host；10..13 释放；READ: >=14 释放；
                                 WRITE: ACK=001 → >=15 host；否则释放。
    """
    if tv_oe_n:
        pts = merge_time_axis(tv_bus, tv_oe_n)
        out, lastv = [], None
        def at(tv, ts):
            last = '0'
            for t, v in tv:
                if t > ts: break
                last = v
            return last
        for ts in pts:
            oe = at(tv_oe_n, ts)
            if oe == '1':
                v = 'z'
            else:
                v = at(tv_mosi if tv_mosi else tv_bus, ts)
            if v != lastv:
                out.append((ts, v)); lastv = v
        return out

    # 无 OE：在帧范围内基于窗口推断
    if not fedges:
        return tv_bus
    def host_owns_bit(i):
        if 0 <= i <= 9: return True
        if 10 <= i <= 13: return False
        if rnw == '1':   # READ
            return False
        if rnw == '0':   # WRITE
            if ack_ok is True:
                return (i >= 15)
            else:
                return False
        return False

    out, lastv = [], None
    for i in range(48):
        ts = (fedges[i] + fedges[i+1]) // 2
        if host_owns_bit(i):
            v = value_at(tv_mosi if tv_mosi else tv_bus, ts)
        else:
            v = 'z'
        if v != lastv:
            out.append((fedges[i], v)); lastv = v
    out.append((fedges[48], lastv if lastv is not None else 'z'))
    return out

def derive_target_tv(tv_bus, host_tv, fedges=None):
    """从机视角：主机驱动时 → Z；否则显示 bus"""
    if not host_tv:
        return tv_bus
    pts = merge_time_axis(tv_bus, host_tv)
    out, lastv = [], None
    def at(tv, ts):
        last = '0'
        for t, v in tv:
            if t > ts: break
            last = v
        return last
    for ts in pts:
        hv = at(host_tv, ts)
        if hv in ('z','Z'):
            v = at(tv_bus, ts)
        else:
            v = 'z'
        if v != lastv:
            out.append((ts, v)); lastv = v
    return out

def label_zone(ax, fedges, b0, b1, text, color):
    ax.axvspan(fedges[b0], fedges[b1], color=color, alpha=0.15, zorder=-3)
    xmid = (fedges[b0] + fedges[b1]) / 2.0
    ax.text(xmid, 0.97, text, transform=ax.get_xaxis_transform(),
            ha="center", va="top", fontsize=FONTSZ_TINY, color="#1f4fbf", zorder=10)

def ack_bits_str(fedges, tv_swdio):
    bits = decode_bits_at(fedges, tv_swdio, 11, 14)
    a0,a1,a2 = (bits + ['x','x','x'])[:3]
    return f"{a2}{a1}{a0}"

def mode_infer_rnw(fedges, tvmap, ack_ok):
    """
    在没有 .rnw 信号时，粗略基于 MOSI 活动推断：
    - ACK=001 后若 15..47 间 MOSI 活动很明显 → WRITE
    - 否则倾向 READ
    """
    if not ack_ok: 
        return '1'  # WAIT/FAULT 更像 READ 的“目标占线或空闲”
    t0 = fedges[15]; t1 = fedges[47]
    mosi_edges = count_edges_in_range(tvmap[".mosi"], t0, t1) if tvmap[".mosi"] else 0
    return '0' if mosi_edges > 4 else '1'

# ===================== 绘制单帧 =====================
def plot_one_frame(figdir: Path, vcd_name: str, ref_to_tv, names, tv, fedges, period, idx,
                   view='host', oe_name=None, mode='auto', debug_times=True):
    xmin, xmax = fedges[0], fedges[48]

    # 先试 ACK
    ack_str = ack_bits_str(fedges, tv[".swdio"])
    ack_ok  = (ack_str == "001")

    # 决定 rnw：mode > .rnw > heuristic
    rnw = 'x'
    if mode == 'read':   rnw = '1'
    elif mode == 'write': rnw = '0'
    elif names[".rnw"] and ref_to_tv.get(names[".rnw"], []):
        rnw = value_at(tv[".rnw"], fedges[0] + max(1, period//10))
    else:
        rnw = mode_infer_rnw(fedges, tv, ack_ok)

    # 数据/奇偶位区间
    if rnw == '1':  # READ
        data_rng, par_rng = (14,46), (46,47)
        data_bits = decode_bits_at(fedges, tv[".swdio"], data_rng[0], data_rng[1])
        par_bit   = decode_bits_at(fedges, tv[".swdio"], par_rng[0], par_rng[1])
        verdict   = "READ_OK" if ack_ok else ("READ_WAIT/FAULT" if ack_str in ("010","100") else "READ(?)")
    else:           # WRITE
        data_rng, par_rng = (15,47), (47,48)
        data_bits = decode_bits_at(fedges, tv[".mosi"],  data_rng[0], data_rng[1])
        par_bit   = decode_bits_at(fedges, tv[".mosi"],  par_rng[0], par_rng[1])
        verdict   = "WRITE_OK" if ack_ok else ("WRITE_WAIT/FAULT" if ack_str in ("010","100") else "WRITE(?)")

    data_val, data_ok = bits_lsb_first_to_int(data_bits)
    par_val = par_bit[0] if par_bit else 'x'
    par_ok  = (ack_ok and data_ok and par_val in ('0','1')
               and int(par_val) == parity_expected_32(data_val))
    data_txt = f"0x{data_val:08X}" if (ack_ok and data_ok) else "—"
    par_txt  = f"{par_val}/" + ("OK" if par_ok else "ERR" if (ack_ok and data_ok and par_val in ('0','1')) else "?")

    # 视角派生：host_tv / tgt_tv / bus_tv
    tv_oe = ref_to_tv.get(oe_name, []) if oe_name else None
    host_tv = derive_host_tv(tv[".swdio"], tv[".mosi"], tv_oe, fedges=fedges, rnw=rnw, ack_ok=ack_ok)
    tgt_tv  = derive_target_tv(tv[".swdio"], host_tv, fedges=fedges)
    bus_tv  = tv[".swdio"]

    # 准备绘图
    title_map = dict(host="Host view (OE→Z)", target="Target view", bus="Bus view (wire)")
    out_dir   = figdir / f"png_{view}"
    out_dir.mkdir(exist_ok=True)
    fig, ax = plt.subplots(figsize=(12, 5), dpi=150)

    # 区块着色 + 标签（READ 无 TA2）
    for (b0,b1,lab) in [(0,2,"PAD"), (2,10,"REQ"), (10,11,"TA1"), (11,14,"ACK")]:
        label_zone(ax, fedges, b0, b1, lab, ZONE_CLR[lab])
    if rnw != '1':
        label_zone(ax, fedges, 14, 15, "TA2", ZONE_CLR["TA2"])
    label_zone(ax, fedges, data_rng[0], data_rng[1], "DATA", ZONE_CLR["DATA"])
    label_zone(ax, fedges, par_rng[0],  par_rng[1],  "PAR",  ZONE_CLR["PAR"])
    ax.axvline(fedges[0],  linewidth=0.8, linestyle="--", alpha=0.5, color="#666")
    ax.axvline(fedges[48], linewidth=0.8, linestyle="--", alpha=0.5, color="#666")

    # 要画的轨：SCK/RST/RNW + 视角 DIO
    lanes = [
        (".sck",  ref_to_tv[names[".sck"]], "sck"),
        (".rst_n",ref_to_tv[names[".rst_n"]] if names[".rst_n"] else [], "rst_n"),
        (".rnw",  ref_to_tv[names[".rnw"]] if names[".rnw"] else [], "rnw"),
    ]
    if view == "host":
        lanes.append(("host", host_tv, "swdio_host"))
    elif view == "target":
        lanes.append(("target", tgt_tv, "swdio_tgt"))
    elif view == "bus":
        lanes.append((".swdio", bus_tv, "swdio_bus"))
    else:  # all
        lanes += [("host", host_tv, "swdio_host"),
                  ("target", tgt_tv, "swdio_tgt"),
                  (".swdio", bus_tv, "swdio_bus")]

    # 画轨
    yoff = 0.0
    for _, tvsig, label in lanes:
        if tvsig:
            t, y = tv_to_step(tvsig, t_end=xmax)
            if t:
                ax.step(t, [yi + yoff for yi in y], where='post', linewidth=LW, clip_on=True)
        ax.text(-0.01, yoff + TRACK_AMP*0.5, label,
                transform=ax.get_yaxis_transform(), ha='right', va='center', fontsize=FONTSZ_LAB)
        ax.hlines(yoff + TRACK_AMP*0.5, xmin, xmax, linestyles='dotted', linewidth=0.6, color='0.75')
        yoff += TRACK_STEP

    # 顶部 bit 刻度
    ax_top = ax.twiny()
    ax_top.set_xlim(xmin, xmax)
    ticks  = [ (fedges[b] + fedges[b+1]) / 2.0 for b in BIT_TICKS ]
    labels = [ str(b) for b in BIT_TICKS ]
    ax_top.set_xticks(ticks); ax_top.set_xticklabels(labels, fontsize=FONTSZ_TINY)
    ax_top.set_xlabel("bit index within frame", fontsize=FONTSZ_LAB, labelpad=6)

    ax.set_xlim(xmin, xmax)
    ax.set_ylim(-0.2, (TRACK_STEP * (len(lanes)-1)) + TRACK_AMP + 0.4)
    ax.set_yticks([])
    ttl_view = title_map.get(view, view)
    mode_tag = f"[mode={mode}] "
    ax.set_title(f"{vcd_name} | Frame {idx:02d} @ {xmin} | {mode_tag}{ttl_view}", fontsize=FONTSZ_MAIN)

    summary  = f"ACK={ack_str}  {verdict:>16}  DATA={data_txt}  PAR={par_txt}"
    if not ref_to_tv.get(names.get(".rnw",""), []):
        summary += "   (rnw=?)"
    if view in ("host","target","all") and not (oe_name and ref_to_tv.get(oe_name, [])):
        summary += "   [OE missing → window inference]"
    fig.text(0.995, 0.995, summary, ha="right", va="top", fontsize=FONTSZ_LAB,
             bbox=dict(boxstyle="round,pad=0.35", facecolor="white", alpha=0.96, lw=0.8))

    if debug_times:
        b0 = (fedges[0]+fedges[1])//2
        b14 = (fedges[14]+fedges[15])//2
        b46 = (fedges[46]+fedges[47])//2
        fig.text(0.01, 0.995, f"b0@{b0}  b14@{b14}  b46@{b46}",
                 ha="left", va="top", fontsize=FONTSZ_TINY,
                 bbox=dict(boxstyle="round,pad=0.2", facecolor="white", alpha=0.9, lw=0.6))

    out = out_dir / f"{Path(vcd_name).stem}_F{idx:02d}_{view}.png"
    plt.tight_layout()
    plt.savefig(out, bbox_inches="tight")
    plt.close()
    print(f"[OK] {vcd_name} F{idx:02d} [{view}] → {out}")

# ===================== RAW 整体视图（无帧） =====================
def plot_raw(figdir: Path, vcd_name: str, ref_to_tv, names, tv, view='bus'):
    xmin = min(t for t,_ in tv[".sck"]) if tv[".sck"] else 0
    xmax = max(t for t,_ in tv[".sck"]) if tv[".sck"] else xmin+100

    out_dir = figdir / f"png_raw"
    out_dir.mkdir(exist_ok=True)
    fig, ax = plt.subplots(figsize=(12, 4.5), dpi=150)

    lanes = [
        (".sck",  ref_to_tv.get(names[".sck"], []),   "sck"),
        (".rst_n",ref_to_tv.get(names[".rst_n"], []), "rst_n"),
        (".mosi", ref_to_tv.get(names[".mosi"], []),  "mosi"),
        (".swdio",ref_to_tv.get(names[".swdio"], []), "swdio_bus"),
    ]

    yoff = 0.0
    for _, tvsig, label in lanes:
        if tvsig:
            t, y = tv_to_step(tvsig, t_end=xmax)
            if t:
                ax.step(t, [yi + yoff for yi in y], where='post', linewidth=LW, clip_on=True)
        ax.text(-0.01, yoff + TRACK_AMP*0.5, label,
                transform=ax.get_yaxis_transform(), ha='right', va='center', fontsize=FONTSZ_LAB)
        ax.hlines(yoff + TRACK_AMP*0.5, xmin, xmax, linestyles='dotted', linewidth=0.6, color='0.75')
        yoff += TRACK_STEP

    ax.set_xlim(xmin, xmax)
    ax.set_ylim(-0.2, (TRACK_STEP * (len(lanes)-1)) + TRACK_AMP + 0.4)
    ax.set_yticks([])
    ax.set_title(f"{vcd_name} | RAW (no frame detected) | view={view}", fontsize=FONTSZ_MAIN)

    out = out_dir / f"{Path(vcd_name).stem}_RAW.png"
    plt.tight_layout()
    plt.savefig(out, bbox_inches="tight")
    plt.close()
    print(f"[OK] {vcd_name} [RAW] → {out}")

# ===================== 主流程 =====================
def main():
    # <<< 必须在函数第一行声明 global，避免“used prior to global declaration” >>>
    global PARITY_MODE, TRACK_AMP, TRACK_STEP

    ap = argparse.ArgumentParser(description="VCD → PNG (per-frame or RAW) with host/target/bus views")
    ap.add_argument("--view", default=DEFAULT_VIEW, choices=("host","target","bus","all"),
                    help="which view to render (frame-mode)")
    ap.add_argument("--glob", default="*.vcd", help="VCD file glob (default: *.vcd)")
    ap.add_argument("--parity", choices=("TB","SWD"), default=PARITY_MODE, help="parity mode")
    ap.add_argument("--amp", type=float, default=TRACK_AMP, help="track amplitude (0..1)")
    ap.add_argument("--step", type=float, default=TRACK_STEP, help="track step")
    ap.add_argument("--mode", choices=("read","write","auto"), default=DEFAULT_MODE,
                    help="render mode: read/write/auto (auto falls back to RAW if no frame detected)")
    ap.add_argument("--map", action="append", default=[],
                    help="explicit mapping, e.g. sck=top.sck swdio=tb.swdio rst_n=tb.rst_n rnw=tb.rnw mosi=tb.mosi miso=tb.miso oe_n=tb.dut.swdio_oe_n_fix")
    args = ap.parse_args()

    # 更新全局参数
    PARITY_MODE = args.parity
    TRACK_AMP   = float(args.amp)
    TRACK_STEP  = float(args.step)

    # 解析 --map
    explicit = {}
    for m in args.map:
        if "=" in m:
            k, v = m.split("=", 1)
            explicit[k.strip()] = v.strip()

    cwd = Path(".").resolve()
    vcds = sorted(cwd.glob(args.glob))
    if not vcds:
        print("[ERR] 当前目录没有匹配的 .vcd"); return

    for vcd_path in vcds:
        v = VCDVCD(str(vcd_path), store_tvs=True)
        ref_to_tv = build_ref_to_tv(v)

        # 取核心信号；优先 --map 指定，否则后缀匹配
        names = {}
        names[".sck"]   = explicit.get("sck")   or pick_by_suffix(ref_to_tv, ".sck")
        names[".rst_n"] = explicit.get("rst_n") or pick_by_suffix(ref_to_tv, ".rst_n")
        names[".rnw"]   = explicit.get("rnw")   or pick_by_suffix(ref_to_tv, ".rnw")
        names[".mosi"]  = explicit.get("mosi")  or pick_by_suffix(ref_to_tv, ".mosi")
        names[".miso"]  = explicit.get("miso")  or pick_by_suffix(ref_to_tv, ".miso")
        names[".swdio"] = explicit.get("swdio") or pick_by_suffix(ref_to_tv, ".swdio")
        oe_name = explicit.get("oe_n")
        if not oe_name:
            for cand in OE_CANDIDATES:
                cand_full = pick_by_suffix(ref_to_tv, cand)
                if cand_full: oe_name = cand_full; break

        # 打印实际选中的全名，和 GTKWave 对一下
        print(f"[SEL] file  = {vcd_path.name}")
        print(f"[SEL] sck   = {names['.sck']}")
        print(f"[SEL] rst_n = {names['.rst_n']}")
        print(f"[SEL] rnw   = {names['.rnw']}")
        print(f"[SEL] mosi  = {names['.mosi']}")
        print(f"[SEL] miso  = {names['.miso']}")
        print(f"[SEL] swdio = {names['.swdio']} (bus)")
        print(f"[SEL] oe_n  = {oe_name or '(none)'}")

        # 必要信号检查
        if not names[".sck"] or not names[".swdio"]:
            print(f"[ERR] {vcd_path.name}: 缺少 .sck 或 .swdio")
            continue

        tvmap = {k: ref_to_tv.get(n, []) if n else [] for k, n in names.items()}
        sck_edges_all = rise_edges(tvmap[".sck"])
        if len(sck_edges_all) < 49:
            # 无法满足单帧 48bit 的最低需求 → 直接 RAW
            print(f"[INFO] {vcd_path.name}: SCK 上升沿不足 49，改为 RAW 渲染")
            outdir = vcd_path.parent / f"{vcd_path.stem}_frames"
            outdir.mkdir(exist_ok=True)
            plot_raw(outdir, vcd_path.name, ref_to_tv, names, tvmap, view="bus")
            continue

        period = sck_edges_all[1] - sck_edges_all[0]

        # 用 rst_n↑ 分帧；没有 rst_n 就仅用开头一帧；auto 下若无法识别 ACK → RAW
        frames = []
        def ack_of(fedges):
            bits = decode_bits_at(fedges, tvmap[".swdio"], 11, 14)
            a0,a1,a2 = (bits+['x','x','x'])[:3]
            return f"{a2}{a1}{a0}"
        def score(fe):
            ack = ack_of(fe)
            return 2 if ack in ("001","010","100") else 0

        if names[".rst_n"]:
            rst_edges = rise_edges(tvmap[".rst_n"])
            for t0 in rst_edges:
                # 严格用 rst↑ 之后的第一拍；并做 ACK 合法性自动校正
                edges0 = [e for e in sck_edges_all if e > t0]
                cands = []
                if len(edges0) >= 49: cands.append(edges0[:49])
                if len(edges0) >= 50: cands.append(edges0[1:50])  # 向右平移 1 拍候选
                if not cands: continue
                best = max(cands, key=score)
                frames.append(best)

        if not frames:
            # 没有 rst 分帧时，先取一帧尝试；若 ACK 不合法且 mode=auto → RAW
            frames = [sck_edges_all[:49]]

        outdir = vcd_path.parent / f"{vcd_path.stem}_frames"
        outdir.mkdir(exist_ok=True)
        print(f"[INFO] {vcd_path.name}: frames={len(frames)} view={args.view} mode={args.mode}")

        # 如果是 auto 且所有候选帧的 ACK 都不是 001/010/100，则直接 RAW
        if args.mode == "auto":
            meaningful = any(score(fe) > 0 for fe in frames)
            if not meaningful:
                print(f"[INFO] {vcd_path.name}: 未识别到有效 ACK（001/010/100），自动降级为 RAW 渲染")
                plot_raw(outdir, vcd_path.name, ref_to_tv, names, tvmap, view="bus")
                continue

        # 逐帧出图
        views = [args.view] if args.view != "all" else ["host","target","bus"]
        for i, fedges in enumerate(frames):
            b0 = (fedges[0]+fedges[1])//2
            b14 = (fedges[14]+fedges[15])//2
            b46 = (fedges[46]+fedges[47])//2
            print(f"[DEBUG] F{i:02d} start={fedges[0]}  b0@{b0}  b14@{b14}  b46@{b46}")
            for vw in views:
                plot_one_frame(outdir, vcd_path.name, ref_to_tv, names, tvmap, fedges, period, i,
                               view=vw, oe_name=oe_name, mode=args.mode)

if __name__ == "__main__":
    main()
