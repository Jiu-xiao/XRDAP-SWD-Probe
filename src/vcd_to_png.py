# vcd_to_png.py — RAW waveform + SWD zone annotation (cycle-pair based)
# Update: y-axis lanes become semantic: clk/rst/rnw + host/target drive/sample

from pathlib import Path
import argparse

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from vcdvcd import VCDVCD

# ===== Visual params =====
TRACK_AMP   = 0.85
TRACK_STEP  = 1.6
LW          = 1.2
FONTSZ_MAIN = 11
FONTSZ_LAB  = 9
FONTSZ_TINY = 8

Y_0 = 0.0
Y_1 = TRACK_AMP
Y_Z = 0.20 * TRACK_AMP
Y_X = 0.70 * TRACK_AMP

SAMPLE_EPS = 1  # avoid sampling exactly at transition timestamp

ZONE_CLR = dict(
    PAD="#cfe9ff",
    REQ="#cfe9ff",
    TA1="#ffd8a8",
    ACK="#ffb3b3",
    TA2="#ffd8a8",
    DATA="#cfe9ff",
    PAR="#d6ffd6",
    TAIL="#e6e6e6",
)

DEFAULT_SUFFIXES = [".sck", ".rst_n", ".rnw", ".mosi", ".miso", ".swdio", ".tb_swdio_en", ".tb_swdio_val"]

# ===== VCD helpers =====
def build_ref_to_tv(v):
    ref_to_tv = {}
    data = getattr(v, "data", {})
    for node in data.values():
        tv = getattr(node, "tv", [])
        if not tv:
            continue
        refs = getattr(node, "references", [])
        if refs:
            for r in refs:
                ref_to_tv[str(r)] = tv
            continue
        nets = getattr(node, "nets", [])
        for net in nets:
            hier = str(getattr(net, "hier", "")).strip(".")
            name = str(getattr(net, "name", "")).strip(".")
            full = (hier + "." + name).strip(".")
            if full:
                ref_to_tv[full] = tv
    return ref_to_tv

def pick_by_suffix(ref_to_tv, suffix):
    return next((full for full in ref_to_tv.keys() if full.endswith(suffix)), "")

def normalize_1bit_val(v):
    if v is None:
        return 'x'
    s = str(v)
    if s in ('0', '1'):
        return s
    if s in ('x', 'X'):
        return 'x'
    if s in ('z', 'Z'):
        return 'z'
    if s.startswith('b') and len(s) >= 2:
        bits = s[1:]
        if len(bits) == 1 and bits in ('0', '1', 'x', 'z', 'X', 'Z'):
            return normalize_1bit_val(bits)
        return 'x'
    return 'x'

def value_at(tv, ts):
    last = '0'
    for t, v in sorted(tv, key=lambda x: x[0]):
        if t > ts:
            break
        last = normalize_1bit_val(v)
    return last

def tv_to_step_1bit(tv, t_end=None):
    if not tv:
        return [], []
    tv = sorted(tv, key=lambda x: x[0])
    tvn = [(t, normalize_1bit_val(v)) for t, v in tv]

    t = [tvn[0][0]]
    yv = [tvn[0][1]]
    last = tvn[0][1]
    for ti, vi in tvn[1:]:
        t += [ti, ti]
        yv += [last, vi]
        last = vi

    if t_end is None:
        t_end = t[-1] + 1
    if t_end > t[-1]:
        t.append(t_end)
        yv.append(last)

    def map_y(v):
        if v == '0': return Y_0
        if v == '1': return Y_1
        if v == 'z': return Y_Z
        return Y_X

    y = [map_y(v) for v in yv]
    return t, y

def collect_time_range(tvs):
    times = []
    for tv in tvs:
        if not tv:
            continue
        times.append(min(t for t, _ in tv))
        times.append(max(t for t, _ in tv))
    if not times:
        return 0, 100
    return min(times), max(times)

def rise_edges(tv):
    tv = sorted(tv, key=lambda x: x[0])
    edges, last = [], None
    for t, v in tv:
        vv = normalize_1bit_val(v)
        if vv == '1' and last != '1':
            edges.append(t)
        last = vv
    return edges

# ===== Build clock cycles: list of (posedge_time, negedge_time) =====
def build_sck_cycles(tv_sck):
    tv = sorted(tv_sck, key=lambda x: x[0])
    last = None
    pending_rise = None
    cycles = []
    for t, v in tv:
        vv = normalize_1bit_val(v)
        if last is None:
            last = vv
            continue
        if vv == last:
            continue
        if vv == '1' and last != '1':
            pending_rise = t
        elif vv == '0' and last == '1' and pending_rise is not None:
            cycles.append((pending_rise, t))
            pending_rise = None
        last = vv
    return cycles

# ===== Sampling instants on cycles =====
def pos_ts(cycles, start_idx, bit_i):
    return cycles[start_idx + bit_i][0] + SAMPLE_EPS

def neg_ts(cycles, start_idx, bit_i):
    return cycles[start_idx + bit_i][1] + SAMPLE_EPS

def t_edge(cycles, start_idx, bit_idx):
    if bit_idx <= 47:
        return cycles[start_idx + bit_idx][0]
    return cycles[start_idx + 47][1]

# ===== Semantic lane derivations =====
def merge_change_times(*tvs):
    ts = set()
    for tv in tvs:
        if not tv:
            continue
        for t, _ in tv:
            ts.add(int(t))
    return sorted(ts)

def derive_target_drive_tv(tv_tb_en, tv_tb_val):
    """
    target_drive = tb_en ? tb_val : Z
    """
    if not tv_tb_en or not tv_tb_val:
        return []
    pts = merge_change_times(tv_tb_en, tv_tb_val)
    out = []
    last = None
    for t in pts:
        en = value_at(tv_tb_en, t)
        if en == '1':
            v = value_at(tv_tb_val, t)
            v = v if v in ('0','1') else 'x'
        else:
            v = 'z'
        if v != last:
            out.append((t, v))
            last = v
    return out

def derive_host_drive_on_wire_tv(tv_mosi, tv_swdio, tv_tb_en=None):
    """
    host_drive = (target not driving) AND (bus not Z) ? MOSI : Z
    - If TB drives (tb_en=1): host_drive=Z
    - Else if bus is Z: host_drive=Z (turnaround / released)
    - Else host_drive = MOSI (what host is putting onto the line through DUT)
    """
    if not tv_mosi or not tv_swdio:
        return []
    pts = merge_change_times(tv_mosi, tv_swdio, tv_tb_en if tv_tb_en else [])
    out = []
    last = None
    for t in pts:
        if tv_tb_en and value_at(tv_tb_en, t) == '1':
            v = 'z'
        else:
            bus = value_at(tv_swdio, t)
            if bus == 'z':
                v = 'z'
            else:
                mv = value_at(tv_mosi, t)
                v = mv if mv in ('0','1') else 'x'
        if v != last:
            out.append((t, v))
            last = v
    return out

def derive_sample_hold_tv_from_cycles(cycles, tv_sig, edge="pos"):
    """
    Build a sample-hold waveform:
      - edge="pos": sample tv_sig at each posedge+eps, update at posedge time
      - edge="neg": sample tv_sig at each negedge+eps, update at negedge time
    """
    if not cycles or not tv_sig:
        return []
    out = []
    last = None
    for (tp, tn) in cycles:
        if edge == "pos":
            t_upd = tp
            t_smp = tp + SAMPLE_EPS
        else:
            t_upd = tn
            t_smp = tn + SAMPLE_EPS
        v = value_at(tv_sig, t_smp)
        if v != last:
            out.append((t_upd, v))
            last = v
    return out

# ===== Decode helpers (annotation only) =====
def bits_lsb_first_to_int(bit_list):
    if not bit_list or any(b not in ('0','1') for b in bit_list):
        return 0, False
    v = 0
    for i, b in enumerate(bit_list):
        if b == '1':
            v |= (1 << i)
    return v, True

def parity_even_32(v):
    return bin(v & 0xFFFFFFFF).count("1") & 1

def target_bit_at(cycles, start_idx, bit_i, tv_swdio, tv_tb_en=None, tv_tb_val=None):
    ts = neg_ts(cycles, start_idx, bit_i)
    vb = value_at(tv_swdio, ts)
    if vb in ('0','1'):
        return vb
    if tv_tb_en and tv_tb_val:
        en = value_at(tv_tb_en, ts)
        if en == '1':
            vv = value_at(tv_tb_val, ts)
            if vv in ('0','1'):
                return vv
    return vb

def decode_req_from_mosi(cycles, start_idx, tv_mosi):
    bits = [value_at(tv_mosi, pos_ts(cycles, start_idx, i)) for i in range(2, 10)]
    val, ok = bits_lsb_first_to_int(bits)
    return bits, val, ok

def decode_ack(cycles, start_idx, tv_swdio, tv_tb_en=None, tv_tb_val=None):
    b0 = target_bit_at(cycles, start_idx, 11, tv_swdio, tv_tb_en, tv_tb_val)
    b1 = target_bit_at(cycles, start_idx, 12, tv_swdio, tv_tb_en, tv_tb_val)
    b2 = target_bit_at(cycles, start_idx, 13, tv_swdio, tv_tb_en, tv_tb_val)
    return [b0,b1,b2], f"{b2}{b1}{b0}"

def infer_rnw(tv_rnw, cycles, start_idx):
    if not tv_rnw:
        return None
    v = value_at(tv_rnw, pos_ts(cycles, start_idx, 0))
    return v if v in ('0','1') else None

# ===== RAW plot =====
def plot_raw(vcd_path: Path, outdir: Path, lanes):
    xmin, xmax = collect_time_range([tv for _, tv in lanes])
    outdir.mkdir(parents=True, exist_ok=True)

    fig, ax = plt.subplots(figsize=(14, 0.9 + 0.75 * max(1, len(lanes))), dpi=150)
    yoff = 0.0
    for name, tv in lanes:
        if tv:
            t, y = tv_to_step_1bit(tv, t_end=xmax)
            if t:
                ax.step(t, [yi + yoff for yi in y], where="post", linewidth=LW, clip_on=True)
        ax.text(-0.01, yoff + TRACK_AMP * 0.5, name,
                transform=ax.get_yaxis_transform(), ha="right", va="center", fontsize=FONTSZ_LAB)
        ax.hlines(yoff + TRACK_AMP * 0.5, xmin, xmax, linestyles="dotted", linewidth=0.6, color="0.75")
        yoff += TRACK_STEP

    ax.set_xlim(xmin, xmax)
    ax.set_ylim(-0.2, (TRACK_STEP * (len(lanes) - 1)) + TRACK_AMP + 0.4)
    ax.set_yticks([])
    ax.set_title(f"{vcd_path.name} | RAW waveform (semantic lanes)", fontsize=FONTSZ_MAIN)
    ax.set_xlabel("time (VCD timescale units)")

    out = outdir / f"{vcd_path.stem}_RAW.png"
    plt.tight_layout()
    plt.savefig(out, bbox_inches="tight")
    plt.close()
    print(f"[OK] RAW  {vcd_path.name} -> {out}")

# ===== Frame plot with zones =====
def shade_zone(ax, cycles, start_idx, b0, b1, label, color):
    x0 = t_edge(cycles, start_idx, b0)
    x1 = t_edge(cycles, start_idx, b1)
    ax.axvspan(x0, x1, color=color, alpha=0.15, zorder=-5)
    xmid = (x0 + x1) / 2.0
    ax.text(xmid, 0.97, label, transform=ax.get_xaxis_transform(),
            ha="center", va="top", fontsize=FONTSZ_TINY, color="#1f4fbf", zorder=10)

def plot_frame(vcd_path: Path, outdir: Path, lanes, cycles, start_idx,
               tv_mosi, tv_swdio, tv_rnw=None, tv_tb_en=None, tv_tb_val=None,
               mode="auto", idx=0):
    xmin = t_edge(cycles, start_idx, 0)
    xmax = t_edge(cycles, start_idx, 48)
    outdir.mkdir(parents=True, exist_ok=True)

    # Decide RNW
    if mode == "read":
        rnw = '1'
    elif mode == "write":
        rnw = '0'
    else:
        rnw = infer_rnw(tv_rnw, cycles, start_idx) or 'x'

    _, req_val, req_ok = decode_req_from_mosi(cycles, start_idx, tv_mosi)
    _, ack_str = decode_ack(cycles, start_idx, tv_swdio, tv_tb_en, tv_tb_val)
    ack_ok = (ack_str == "001")

    if rnw == '1':  # READ
        data_bits = [target_bit_at(cycles, start_idx, i, tv_swdio, tv_tb_en, tv_tb_val) for i in range(14, 46)]
        par_bit   = target_bit_at(cycles, start_idx, 46, tv_swdio, tv_tb_en, tv_tb_val)
        tail_bit  = target_bit_at(cycles, start_idx, 47, tv_swdio, tv_tb_en, tv_tb_val)

        data_val, data_ok = bits_lsb_first_to_int(data_bits)
        par_ok = (ack_ok and data_ok and par_bit in ('0','1') and int(par_bit) == parity_even_32(data_val))

        data_txt = f"0x{data_val:08X}" if (ack_ok and data_ok) else "—"
        par_txt  = f"{par_bit}/" + ("OK" if par_ok else ("ERR" if (ack_ok and data_ok and par_bit in ('0','1')) else "?"))
        verdict  = "READ_OK" if ack_ok else ("READ_WAIT/FAULT" if ack_str in ("010","100") else "READ(?)")
        tail_txt = f" TAIL={tail_bit}"
    else:           # WRITE
        data_bits = [value_at(tv_mosi, pos_ts(cycles, start_idx, i)) for i in range(15, 47)]
        par_bit   = value_at(tv_mosi, pos_ts(cycles, start_idx, 47))

        data_val, data_ok = bits_lsb_first_to_int(data_bits)
        par_ok = (ack_ok and data_ok and par_bit in ('0','1') and int(par_bit) == parity_even_32(data_val))

        data_txt = f"0x{data_val:08X}" if (ack_ok and data_ok) else "—"
        par_txt  = f"{par_bit}/" + ("OK" if par_ok else ("ERR" if (ack_ok and data_ok and par_bit in ('0','1')) else "?"))
        verdict  = "WRITE_OK" if ack_ok else ("WRITE_WAIT/FAULT" if ack_str in ("010","100") else "WRITE(?)")
        tail_txt = ""

    fig, ax = plt.subplots(figsize=(14, 0.9 + 0.75 * max(1, len(lanes))), dpi=150)

    yoff = 0.0
    for name, tv in lanes:
        if tv:
            t, y = tv_to_step_1bit(tv, t_end=xmax)
            if t:
                ax.step(t, [yi + yoff for yi in y], where="post", linewidth=LW, clip_on=True)
        ax.text(-0.01, yoff + TRACK_AMP * 0.5, name,
                transform=ax.get_yaxis_transform(), ha="right", va="center", fontsize=FONTSZ_LAB)
        ax.hlines(yoff + TRACK_AMP * 0.5, xmin, xmax, linestyles="dotted", linewidth=0.6, color="0.75")
        yoff += TRACK_STEP

    # Zones
    shade_zone(ax, cycles, start_idx, 0,  2,  "PAD",  ZONE_CLR["PAD"])
    shade_zone(ax, cycles, start_idx, 2,  10, "REQ",  ZONE_CLR["REQ"])
    shade_zone(ax, cycles, start_idx, 10, 11, "TA1",  ZONE_CLR["TA1"])
    shade_zone(ax, cycles, start_idx, 11, 14, "ACK",  ZONE_CLR["ACK"])
    if rnw == '1':
        shade_zone(ax, cycles, start_idx, 14, 46, "DATA", ZONE_CLR["DATA"])
        shade_zone(ax, cycles, start_idx, 46, 47, "PAR",  ZONE_CLR["PAR"])
        shade_zone(ax, cycles, start_idx, 47, 48, "TAIL", ZONE_CLR["TAIL"])
    else:
        shade_zone(ax, cycles, start_idx, 14, 15, "TA2",  ZONE_CLR["TA2"])
        shade_zone(ax, cycles, start_idx, 15, 47, "DATA", ZONE_CLR["DATA"])
        shade_zone(ax, cycles, start_idx, 47, 48, "PAR",  ZONE_CLR["PAR"])

    ax.set_xlim(xmin, xmax)
    ax.set_ylim(-0.2, (TRACK_STEP * (len(lanes) - 1)) + TRACK_AMP + 0.4)
    ax.set_yticks([])
    ax.set_title(f"{vcd_path.name} | Frame {idx:02d} | RAW + Zones", fontsize=FONTSZ_MAIN)
    ax.set_xlabel("time (VCD timescale units)")

    req_txt = f"0x{req_val:02X}" if req_ok else "—"
    summary = f"RNW={rnw} REQ={req_txt} ACK={ack_str} {verdict} DATA={data_txt} PAR={par_txt}{tail_txt}"
    fig.text(0.995, 0.995, summary, ha="right", va="top", fontsize=FONTSZ_LAB,
             bbox=dict(boxstyle="round,pad=0.35", facecolor="white", alpha=0.96, lw=0.8))

    out = outdir / f"{vcd_path.stem}_F{idx:02d}_ZONES.png"
    plt.tight_layout()
    plt.savefig(out, bbox_inches="tight")
    plt.close()
    print(f"[OK] FRAME {vcd_path.name} -> {out}")

# ===== Frame alignment search (cycle-based) =====
def frame_score(cycles, start_idx, tv_mosi, tv_swdio, tv_tb_en=None, tv_tb_val=None):
    score = 0
    for i in (0, 1):
        if value_at(tv_mosi, pos_ts(cycles, start_idx, i)) == '0':
            score += 1
    bus10 = value_at(tv_swdio, neg_ts(cycles, start_idx, 10))
    if bus10 == 'z':
        score += 2
    else:
        if tv_tb_en and value_at(tv_tb_en, neg_ts(cycles, start_idx, 10)) == '0':
            score += 1
    _, ack_str = decode_ack(cycles, start_idx, tv_swdio, tv_tb_en, tv_tb_val)
    if ack_str in ("001", "010", "100"):
        score += 8
    for bi in (11, 12, 13):
        b = target_bit_at(cycles, start_idx, bi, tv_swdio, tv_tb_en, tv_tb_val)
        if b in ('0','1'):
            score += 1
    return score, ack_str

def find_best_frames_after_rst(cycles, rst_rises, tv_mosi, tv_swdio, tv_tb_en=None, tv_tb_val=None,
                              max_shift=32, min_score=8):
    out = []
    n = len(cycles)
    if n < 48:
        return out
    for t0 in rst_rises:
        base = None
        for i in range(n):
            if cycles[i][0] > t0:
                base = i
                break
        if base is None:
            continue
        best = None
        for sh in range(0, max_shift):
            s = base + sh
            if s + 48 > n:
                break
            sc, ack = frame_score(cycles, s, tv_mosi, tv_swdio, tv_tb_en, tv_tb_val)
            cand = (sc, ack, s)
            if (best is None) or (cand[0] > best[0]):
                best = cand
        if best and best[0] >= min_score:
            sc, ack, s = best
            out.append((sc, ack, s, cycles[s][0]))
    return out

# ===== Main =====
def main():
    ap = argparse.ArgumentParser(description="Render RAW VCD waveforms + SWD zone annotation (semantic lanes).")
    ap.add_argument("--glob", default="*.vcd", help="VCD glob")
    ap.add_argument("--outdir", default="vcd_png", help="output directory root")
    ap.add_argument("--mode", choices=("auto","read","write"), default="auto")
    ap.add_argument("--default", action="store_true",
                    help="use semantic lanes (clk/rst/rnw + host/target drive/sample)")
    ap.add_argument("--map", action="append", default=[],
                    help="explicit mapping: sck=... swdio=... mosi=... rst_n=... rnw=... tb_en=... tb_val=...")
    ap.add_argument("--max_shift", type=int, default=32, help="alignment search shift (cycles)")
    ap.add_argument("--min_score", type=int, default=8, help="minimum score to accept a frame")
    ap.add_argument("--no_frames", action="store_true", help="only RAW, skip annotation")
    args = ap.parse_args()

    explicit = {}
    for m in args.map:
        if "=" in m:
            k, v = m.split("=", 1)
            explicit[k.strip()] = v.strip()

    vcds = sorted(Path(".").glob(args.glob))
    if not vcds:
        print("[ERR] no VCD matched")
        return

    outroot = Path(args.outdir)
    out_raw = outroot / "raw"
    out_fr  = outroot / "frames"

    for vcd_path in vcds:
        v = VCDVCD(str(vcd_path), store_tvs=True)
        ref_to_tv = build_ref_to_tv(v)

        sck_name   = explicit.get("sck")   or pick_by_suffix(ref_to_tv, ".sck")
        rst_name   = explicit.get("rst_n") or pick_by_suffix(ref_to_tv, ".rst_n")
        rnw_name   = explicit.get("rnw")   or pick_by_suffix(ref_to_tv, ".rnw")
        mosi_name  = explicit.get("mosi")  or pick_by_suffix(ref_to_tv, ".mosi")
        swdio_name = explicit.get("swdio") or pick_by_suffix(ref_to_tv, ".swdio")
        tb_en_name = explicit.get("tb_en") or pick_by_suffix(ref_to_tv, ".tb_swdio_en")
        tb_val_name= explicit.get("tb_val")or pick_by_suffix(ref_to_tv, ".tb_swdio_val")

        print(f"[SEL] file={vcd_path.name}")
        print(f"[SEL]  sck={sck_name}")
        print(f"[SEL]  rst_n={rst_name or '(none)'}")
        print(f"[SEL]  rnw={rnw_name or '(none)'}")
        print(f"[SEL]  mosi={mosi_name or '(none)'}")
        print(f"[SEL]  swdio={swdio_name or '(none)'}")
        print(f"[SEL]  tb_en={tb_en_name or '(none)'}")
        print(f"[SEL]  tb_val={tb_val_name or '(none)'}")

        tv_sck   = ref_to_tv.get(sck_name, []) if sck_name else []
        tv_rst   = ref_to_tv.get(rst_name, []) if rst_name else []
        tv_rnw   = ref_to_tv.get(rnw_name, []) if rnw_name else []
        tv_mosi  = ref_to_tv.get(mosi_name, []) if mosi_name else []
        tv_swdio = ref_to_tv.get(swdio_name, []) if swdio_name else []
        tv_tb_en = ref_to_tv.get(tb_en_name, []) if tb_en_name else []
        tv_tb_val= ref_to_tv.get(tb_val_name, []) if tb_val_name else []

        cycles = build_sck_cycles(tv_sck) if tv_sck else []
        print(f"[INFO] {vcd_path.name}: sck_cycles={len(cycles)}")

        # --- build semantic lanes ---
        lanes = []
        lanes.append(("clk (SCK)", tv_sck))
        lanes.append(("rst_n", tv_rst))
        lanes.append(("rnw (1=READ)", tv_rnw))

        host_drive = derive_host_drive_on_wire_tv(tv_mosi, tv_swdio, tv_tb_en if tv_tb_en else None)
        host_samp  = derive_sample_hold_tv_from_cycles(cycles, tv_swdio, edge="pos") if cycles else []
        tgt_drive  = derive_target_drive_tv(tv_tb_en, tv_tb_val) if (tv_tb_en and tv_tb_val) else []
        tgt_samp   = derive_sample_hold_tv_from_cycles(cycles, tv_swdio, edge="neg") if cycles else []

        lanes.append(("host_drive (to SWDIO)", host_drive))
        lanes.append(("host_sample (SWDIO @posedge)", host_samp))
        lanes.append(("target_drive (TB)", tgt_drive))
        lanes.append(("target_sample (SWDIO @negedge)", tgt_samp))

        # RAW always
        plot_raw(vcd_path, out_raw, lanes)

        if args.no_frames:
            continue

        if not (tv_sck and tv_mosi and tv_swdio and cycles and len(cycles) >= 48):
            print(f"[INFO] {vcd_path.name}: insufficient signals/cycles for frame annotation")
            continue

        rst_rises = rise_edges(tv_rst) if tv_rst else []
        if not rst_rises:
            rst_rises = [-1]  # allow scan from start (special likely won't score)

        best = find_best_frames_after_rst(
            cycles, rst_rises, tv_mosi, tv_swdio,
            tv_tb_en if tv_tb_en else None,
            tv_tb_val if tv_tb_val else None,
            max_shift=args.max_shift, min_score=args.min_score
        )

        if args.mode == "auto" and not best:
            print(f"[INFO] {vcd_path.name}: no frame >=min_score (likely RAW-only capture)")
            continue

        for i, (sc, ack, start_idx, start_time) in enumerate(best):
            print(f"[INFO] {vcd_path.name}: frame#{i} score={sc} ack={ack} start_idx={start_idx} start_t={start_time}")
            plot_frame(
                vcd_path, out_fr, lanes, cycles, start_idx,
                tv_mosi=tv_mosi, tv_swdio=tv_swdio, tv_rnw=tv_rnw,
                tv_tb_en=(tv_tb_en if tv_tb_en else None),
                tv_tb_val=(tv_tb_val if tv_tb_val else None),
                mode=args.mode, idx=i
            )

if __name__ == "__main__":
    main()
