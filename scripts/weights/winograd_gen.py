"""
winograd_gen.py  —  Conv2 복소수 Winograd F(4,3) RTL 생성기 + bit-exact hw-model
================================================================================

목적 (RTL 작성 전 de-risk):
  1. **hw_model**: 실제 RTL 데이터패스를 그대로 옮긴 정수 모델
       d(6×6) → V=BᵀdB (input transform)
              → M = Σ_IC U⊙V  (46 real-mul, Gauss trick, 26 계산 + 10 켤레유도)
              → Y16 = AᵀMA (output transform)
              → out = sat(Y16>>14)+ReLU
     이 hw_model 이 golden(`1_complex_winograd_f(4,3).py`)과 **bit-exact** 임을 검증.
     → RTL 은 이 hw_model 을 그대로 구현하면 됨 (golden = 최종 정답).
  2. **bit-width**: 각 stage 의 실제/이론 최대 절댓값 → RTL register 폭 결정 (overflow=버그).
  3. (2nd pass) RTL emit: wino_input_transform.v / wino_output_transform.v +
     U weight pre-pack hex/header + 46-position/Gauss 매핑표.

행렬은 golden(§9.1 정정판)과 1:1 — importlib 로 golden 을 로드해 행렬 동일성 assert.

실행:
  python3 scripts/weights/winograd_gen.py            # 전체 검증 + 리포트 (+ emit)
  WINO_N=200 python3 scripts/weights/winograd_gen.py # 앞 200장만 (빠름)
"""

from __future__ import annotations

import os
import sys
import importlib.util
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.normpath(os.path.join(HERE, "..", "golden_sim"))
DATA_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "data", "_base_npy"))
sys.path.insert(0, GOLDEN_DIR)
import reference_core as rc  # noqa: E402


# =============================================================================
# 0.  변환 행렬 (Gaussian integer, real/imag int64) — golden §9.1 정정판과 1:1
# =============================================================================
# 점집합 {0, 1, -1, i, -i, ∞}  (행/열 index 0..5)
G_RE = np.array([[1, 0, 0], [1, 1, 1], [1, -1, 1],
                 [1, 0, -1], [1, 0, -1], [0, 0, 1]], dtype=np.int64)
G_IM = np.array([[0, 0, 0], [0, 0, 0], [0, 0, 0],
                 [0, 1, 0], [0, -1, 0], [0, 0, 0]], dtype=np.int64)

BT_RE = np.array([[4, 0, 0, 0, -4, 0], [0, 1, 1, 1, 1, 0], [0, -1, 1, -1, 1, 0],
                  [0, 0, -1, 0, 1, 0], [0, 0, -1, 0, 1, 0], [0, -4, 0, 0, 0, 4]], dtype=np.int64)
BT_IM = np.array([[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0],
                  [0, -1, 0, 1, 0, 0], [0, 1, 0, -1, 0, 0], [0, 0, 0, 0, 0, 0]], dtype=np.int64)

AT_RE = np.array([[1, 1, 1, 1, 1, 0], [0, 1, -1, 0, 0, 0],
                  [0, 1, 1, -1, -1, 0], [0, 1, -1, 0, 0, 1]], dtype=np.int64)
AT_IM = np.array([[0, 0, 0, 0, 0, 0], [0, 0, 0, 1, -1, 0],
                  [0, 0, 0, 0, 0, 0], [0, 0, 0, -1, 1, 0]], dtype=np.int64)

# 우측 곱 transpose
GT_RE, GT_IM = G_RE.T.copy(), G_IM.T.copy()
B_RE, B_IM = BT_RE.T.copy(), BT_IM.T.copy()
A_RE, A_IM = AT_RE.T.copy(), AT_IM.T.copy()

M_TILE, R_KERNEL = 4, 3
TILE_IN = 6
OUT_SHIFT = 14          # >>(layer 10 + winograd 4)


def cmatmul(Lr, Li, Rr, Ri):
    """복소수 행렬곱 (마지막 두 축). 전부 int64 → bit-exact."""
    return (Lr @ Rr - Li @ Ri, Lr @ Ri + Li @ Rr)


# =============================================================================
# 1.  Position 분류 + Gauss 매핑 (46 real-mul 의 정확한 구조)
# =============================================================================
#   점 index 0..5 = {0,1,-1,i,-i,∞}. real 점={0,1,2,5}, complex 점={3,4}(i,-i 켤레쌍).
REAL_PTS = (0, 1, 2, 5)
CPLX_PTS = (3, 4)


def conj_idx(k):
    """점 index 의 켤레 (i↔-i, 실수점은 자기 자신)."""
    return {3: 4, 4: 3}.get(k, k)


def classify_positions():
    """6×6=36 position 을 분류.
    returns dict:
      real_pos   : 16개 (p,q) — U,V 실수, M 실수, 1 real-mul
      cmul_pos   : 10개 대표 (p,q) — complex×complex, Gauss 3 real-mul (계산)
      conj_map   : {derived (p,q): rep (p,q)} 10개 — M[derived]=conj(M[rep])
    """
    real_pos, cmul_pos, conj_map = [], [], {}
    seen = set()
    for p in range(6):
        for q in range(6):
            if p in REAL_PTS and q in REAL_PTS:
                real_pos.append((p, q))
            else:
                cp, cq = conj_idx(p), conj_idx(q)
                partner = (cp, cq)
                if (p, q) in seen:
                    continue
                # 대표 = 사전순 min(self, partner)
                rep = min((p, q), partner)
                der = max((p, q), partner)
                cmul_pos.append(rep)
                conj_map[der] = rep
                seen.add(rep)
                seen.add(der)
    assert len(real_pos) == 16, len(real_pos)
    assert len(cmul_pos) == 10, len(cmul_pos)
    assert len(conj_map) == 10, len(conj_map)
    # 합 = 36
    assert 16 + 10 + 10 == 36
    return real_pos, sorted(cmul_pos), conj_map


REAL_POS, CMUL_POS, CONJ_MAP = classify_positions()


# =============================================================================
# 2.  Weight pre-pack:  U = G·g·Gᵀ  →  46-operand weight layout (per OC,IC)
# =============================================================================
#   real position (p,q):     weight = U_re[p,q]                (V_re 와 곱)
#   complex position (p,q):  Gauss weight 3개 {a, b-a, a+b}
#                              a=U_re, b=U_im
#                              k1 = a*(c+d), k2 = c*(b-a), k3 = d*(a+b)
#                              → DSP A-port = {a, b-a, a+b}, B-port = {(c+d), c, d}
def compute_U(w2):
    """w2 (16,8,3,3) int8 → U_re,U_im (16,8,6,6) int64.  G 스케일 없음(정수)."""
    g = w2.astype(np.int64)
    z = np.zeros_like(g)
    s_re, s_im = cmatmul(G_RE, G_IM, g, z)
    U_re, U_im = cmatmul(s_re, s_im, GT_RE, GT_IM)
    return U_re, U_im


def weight_operands(U_re, U_im, oc, ic):
    """(oc,ic) 의 46 weight operand 를 canonical 순서로 반환.
       순서 = [real_pos 16] + [cmul_pos 각 (a, b-a, a+b) 30] = 46.
       real position 의 U_im 은 0 이어야 함(assert)."""
    ops = []
    for (p, q) in REAL_POS:
        assert U_im[oc, ic, p, q] == 0, f"real pos {(p,q)} U_im!=0"
        ops.append(int(U_re[oc, ic, p, q]))
    for (p, q) in CMUL_POS:
        a = int(U_re[oc, ic, p, q])
        b = int(U_im[oc, ic, p, q])
        ops.extend([a, b - a, a + b])
    assert len(ops) == 46
    return ops


# =============================================================================
# 3.  Input transform:  V = Bᵀ·d·B  →  46 activation operand (B-port feeds)
# =============================================================================
#   real position:  activation = V_re
#   complex pos:    activation = {(V_re+V_im), V_re, V_im}  (k1,k2,k3 의 B-port)
def input_transform(d6):
    """d6 (...,6,6) int64 → V_re,V_im (...,6,6)."""
    dz = np.zeros_like(d6)
    t_re, t_im = cmatmul(BT_RE, BT_IM, d6, dz)
    V_re, V_im = cmatmul(t_re, t_im, B_RE, B_IM)
    return V_re, V_im


def activation_operands(V_re, V_im):
    """V (...,6,6) → 46 activation operand array (..., 46) canonical 순서.
       real pos 의 V_im 은 0 이어야 함."""
    shape = V_re.shape[:-2]
    ops = np.empty(shape + (46,), dtype=np.int64)
    idx = 0
    for (p, q) in REAL_POS:
        assert np.all(V_im[..., p, q] == 0), f"real pos {(p,q)} V_im!=0"
        ops[..., idx] = V_re[..., p, q]; idx += 1
    for (p, q) in CMUL_POS:
        c = V_re[..., p, q]
        dd = V_im[..., p, q]
        ops[..., idx] = c + dd; idx += 1   # k1 B-port
        ops[..., idx] = c;      idx += 1   # k2 B-port
        ops[..., idx] = dd;     idx += 1   # k3 B-port
    assert idx == 46
    return ops


# =============================================================================
# 4.  hw-model 핵심:  46-mul Gauss → 6×6 complex M  (1 (OC,tile))
# =============================================================================
def mul_array_M(w_ops_ic, a_ops_ic):
    """한 (OC,tile) 의 M (6×6 complex) 을 46-mul Gauss + 켤레유도로 계산.
       w_ops_ic : (8, 46)  weight operand (8 IC)
       a_ops_ic : (8, 46)  activation operand (8 IC)
       returns M_re,M_im (6,6) int64.
    실제 RTL 과 동일하게: 각 IC 의 46 곱 → position partial → IC 합 → 켤레유도.
    """
    M_re = np.zeros((6, 6), dtype=np.int64)
    M_im = np.zeros((6, 6), dtype=np.int64)

    # real positions (operand index 0..15)
    for i, (p, q) in enumerate(REAL_POS):
        # Σ_IC  a(weight U_re) * b(act V_re)
        prod = w_ops_ic[:, i] * a_ops_ic[:, i]     # (8,)
        M_re[p, q] = prod.sum()
        M_im[p, q] = 0

    # complex positions (operand index 16.. in groups of 3)
    base = 16
    for j, (p, q) in enumerate(CMUL_POS):
        wbase = base + 3 * j
        a_w = w_ops_ic[:, wbase + 0]   # a
        bma = w_ops_ic[:, wbase + 1]   # b-a
        apb = w_ops_ic[:, wbase + 2]   # a+b
        cpd = a_ops_ic[:, wbase + 0]   # c+d
        cc = a_ops_ic[:, wbase + 1]    # c
        dd = a_ops_ic[:, wbase + 2]    # d
        k1 = a_w * cpd
        k2 = cc * bma
        k3 = dd * apb
        re = (k1 - k3).sum()
        im = (k1 + k2).sum()
        M_re[p, q] = re
        M_im[p, q] = im

    # 켤레유도 10개
    for der, rep in CONJ_MAP.items():
        M_re[der[0], der[1]] = M_re[rep[0], rep[1]]
        M_im[der[0], der[1]] = -M_im[rep[0], rep[1]]

    return M_re, M_im


def output_transform(M_re, M_im):
    """Y16 = Aᵀ·M·A (4×4 real). imag==0 assert."""
    y_re, y_im = cmatmul(AT_RE, AT_IM, M_re, M_im)
    Y16_re, Y16_im = cmatmul(y_re, y_im, A_RE, A_IM)
    return Y16_re, Y16_im


# =============================================================================
# 5.  전체 hw-model forward  (한 image, conv2 winograd) + bit-width tracking
# =============================================================================
class Stats:
    def __init__(self):
        self.maxabs = {}
    def upd(self, key, arr):
        m = int(np.abs(np.asarray(arr, dtype=np.int64)).max(initial=0))
        if m > self.maxabs.get(key, 0):
            self.maxabs[key] = m


def hw_forward(f1, U_re, U_im, stats: Stats):
    """f1 (N,8,26,26) int8 → conv2 winograd out (N,16,24,24) int8 (sat, no relu).
       hw_model: 실제 RTL 데이터패스 그대로(46-mul Gauss, IC 합, 켤레, AᵀMA, >>14).
    """
    N, Cin, H, W = f1.shape
    Cout = U_re.shape[0]
    Ho, Wo = H - 2, W - 2
    out = np.empty((N, Cout, Ho, Wo), dtype=np.int8)
    x64 = f1.astype(np.int64)

    # weight operand (16 OC, 8 IC, 46)
    W_ops = np.empty((Cout, Cin, 46), dtype=np.int64)
    for oc in range(Cout):
        for ic in range(Cin):
            W_ops[oc, ic] = weight_operands(U_re, U_im, oc, ic)
    stats.upd("U_re", U_re); stats.upd("U_im", U_im)
    stats.upd("w_operand", W_ops)

    for ty in range(Ho // M_TILE):
        for tx in range(Wo // M_TILE):
            r0, c0 = ty * M_TILE, tx * M_TILE
            d = x64[:, :, r0:r0 + TILE_IN, c0:c0 + TILE_IN]   # (N,8,6,6)
            stats.upd("d", d)
            # input transform per (N,IC)
            V_re, V_im = input_transform(d)
            stats.upd("t_intermediate_skip", 0)
            stats.upd("V_re", V_re); stats.upd("V_im", V_im)
            A_ops = activation_operands(V_re, V_im)           # (N,8,46)
            stats.upd("a_operand", A_ops)
            for n in range(N):
                for oc in range(Cout):
                    M_re, M_im = mul_array_M(W_ops[oc], A_ops[n])
                    stats.upd("M_re", M_re); stats.upd("M_im", M_im)
                    Y16_re, Y16_im = output_transform(M_re, M_im)
                    stats.upd("Y16", Y16_re)
                    assert (Y16_im == 0).all(), f"imag!=0 @({n},{oc},{ty},{tx})"
                    assert (Y16_re % 16 == 0).all(), "Y16 not /16"
                    shifted = Y16_re >> OUT_SHIFT
                    out[n, oc, r0:r0 + M_TILE, c0:c0 + M_TILE] = \
                        np.clip(shifted, -128, 127).astype(np.int8)
    return out


# =============================================================================
# 6.  golden 모듈 로드 + 행렬 동일성 assert
# =============================================================================
def _sbits(v):
    """signed bits needed to hold [-v, v]."""
    v = int(v)
    if v == 0:
        return 1
    return int(np.ceil(np.log2(v + 1))) + 1


def relu_bounds(U_re, U_im, margin=1):
    """d∈[0,127] (conv2 입력 = relu(conv1)) **이론 worst-case** → RTL 폭 결정.
       선형/이중선형 전개의 삼각부등식 상한 → 어떤 relu 입력에도 overflow 없음(safe),
       그러나 ±128 가정보다 작음(LUT 절감). 각 stage 폭 = sbits(bound)+margin.
    """
    DMAX = 127

    def one_sided(coef):  # max |Σ c·d|, d∈[0,127]
        c = np.asarray(coef, dtype=np.int64)
        return DMAX * int(max(c[c > 0].sum(), -c[c < 0].sum()))

    # t = Bᵀ·d  (per row p)
    tw = 0
    for p in range(6):
        tw = max(tw, one_sided(BT_RE[p]), one_sided(BT_IM[p]))

    # V[p][q] = Σ_{k,l} Bᵀ[p,k]·Bᵀ[q,l]·d[k][l]
    Vw_re = np.zeros((6, 6), dtype=np.int64)
    Vw_im = np.zeros((6, 6), dtype=np.int64)
    for p in range(6):
        for q in range(6):
            cre = np.outer(BT_RE[p], BT_RE[q]) - np.outer(BT_IM[p], BT_IM[q])
            cim = np.outer(BT_RE[p], BT_IM[q]) + np.outer(BT_IM[p], BT_RE[q])
            Vw_re[p, q] = one_sided(cre.reshape(-1))
            Vw_im[p, q] = one_sided(cim.reshape(-1))

    # activation operand worst (B-port): real pos = V_re ; cmul = {V_re+V_im, V_re, V_im}
    aw = 0
    for (p, q) in REAL_POS:
        aw = max(aw, int(Vw_re[p, q]))
    for (p, q) in CMUL_POS:
        aw = max(aw, int(Vw_re[p, q] + Vw_im[p, q]))
    # weight operand worst (fixed model)
    wop = 0
    for oc in range(16):
        for ic in range(8):
            wop = max(wop, max(abs(x) for x in weight_operands(U_re, U_im, oc, ic)))
    kw = wop * aw                                   # DSP product

    # M = Σ_IC U⊙V  (|M_re|≤Σ|U_re||V_re|+|U_im||V_im|, V≤Vw per IC)
    sUre = np.abs(U_re).sum(axis=1)                 # (16,6,6) Σ_ic|U_re|
    sUim = np.abs(U_im).sum(axis=1)
    Mw_re = (Vw_re * sUre + Vw_im * sUim).max(axis=0)   # (6,6)
    Mw_im = (Vw_re * sUim + Vw_im * sUre).max(axis=0)
    Mw = int(max(Mw_re.max(), Mw_im.max()))

    # y = Aᵀ·M ; Y16 = y·A   (계수 {0,±1})
    aAT_re, aAT_im = np.abs(AT_RE), np.abs(AT_IM)
    yw_re = aAT_re @ Mw_re + aAT_im @ Mw_im         # (4,6)
    yw_im = aAT_re @ Mw_im + aAT_im @ Mw_re
    Y16w = yw_re @ aAT_re.T + yw_im @ aAT_im.T       # (4,4)
    yw = int(max(yw_re.max(), yw_im.max(), Y16w.max()))

    widths = {
        "DW": 8,
        "TW": _sbits(tw) + margin,
        "VW": _sbits(max(int(Vw_re.max()), int(Vw_im.max()), aw)) + margin,
        "UW": _sbits(wop) + margin,
        "PW": _sbits(kw) + margin,
        "MW": _sbits(Mw) + margin,
        "YW": _sbits(yw) + margin,
    }
    print("\n[R] d∈[0,127] 이론 worst-case → 권장 RTL 폭 (safe, +%d margin)" % margin)
    print(f"    t={tw}  V={max(int(Vw_re.max()),int(Vw_im.max()))} a_op={aw}  w_op={wop}  "
          f"k={kw}  M={Mw}  y/Y16={yw}")
    print(f"    → DW={widths['DW']} TW={widths['TW']} VW={widths['VW']} UW={widths['UW']} "
          f"PW={widths['PW']} MW={widths['MW']} YW={widths['YW']}")
    return widths


def bitwidth_report(f1_full, U_re, U_im):
    """전체 10000장(실 입력) empirical max + 이론 worst-case(d∈[-128,127]) → RTL 폭.
       hw 가 실제로 보는 d 는 relu(conv1)∈[0,127] 이지만, RTL 은 어떤 int8 입력에도
       overflow 없어야 하므로 이론 worst case(±128)도 함께 보고."""
    print("\n[C] bit-width 분석 (전체 %d장 empirical + 이론 worst-case)" % f1_full.shape[0])

    # ---- 이론 worst-case: transform 계수합 × max|d| ----
    # V[p,q] = Σ_{k,l} Bᵀ[p,k]·Bᵀ[q,l]·d[k,l]   (B[l,q]=Bᵀ[q,l])
    DMAX = 128  # int8 worst |d|
    vre_wc = vim_wc = 0
    for p in range(6):
        for q in range(6):
            # 계수(복소) of d[k,l] = Bᵀ[p,k]·Bᵀ[q,l]
            cre = np.outer(BT_RE[p], BT_RE[q]) - np.outer(BT_IM[p], BT_IM[q])
            cim = np.outer(BT_RE[p], BT_IM[q]) + np.outer(BT_IM[p], BT_RE[q])
            vre_wc = max(vre_wc, int(np.abs(cre).sum()) * DMAX)
            vim_wc = max(vim_wc, int(np.abs(cim).sum()) * DMAX)
    a_wc = max(vre_wc + vim_wc, vre_wc)   # a_operand 최대 = (V_re+V_im) 항
    # weight operand (이미지 무관, 실 weight 로 정확)
    wop_max = 0
    for oc in range(16):
        for ic in range(8):
            wop_max = max(wop_max, max(abs(x) for x in weight_operands(U_re, U_im, oc, ic)))
    k_wc = wop_max * a_wc                  # DSP 곱 1개 worst
    m_wc = 8 * 2 * k_wc                    # Σ_8IC (k1±k3) worst (complex)

    # ---- empirical: 전체 이미지 loop(36 tile, N vectorized) ----
    emp = {k: 0 for k in ["V_re", "V_im", "a_op", "M_re", "M_im", "Y16"]}
    x64 = f1_full.astype(np.int64)
    for ty in range(6):
        for tx in range(6):
            r0, c0 = ty * 4, tx * 4
            d = x64[:, :, r0:r0 + 6, c0:c0 + 6]              # (N,8,6,6)
            V_re, V_im = input_transform(d)
            A_ops = activation_operands(V_re, V_im)          # (N,8,46)
            emp["V_re"] = max(emp["V_re"], int(np.abs(V_re).max()))
            emp["V_im"] = max(emp["V_im"], int(np.abs(V_im).max()))
            emp["a_op"] = max(emp["a_op"], int(np.abs(A_ops).max()))
            # M = Σ_IC U⊙V  (einsum, golden 식)
            M_re = (np.einsum('oipq,nipq->nopq', U_re, V_re)
                    - np.einsum('oipq,nipq->nopq', U_im, V_im))
            M_im = (np.einsum('oipq,nipq->nopq', U_re, V_im)
                    + np.einsum('oipq,nipq->nopq', U_im, V_re))
            emp["M_re"] = max(emp["M_re"], int(np.abs(M_re).max()))
            emp["M_im"] = max(emp["M_im"], int(np.abs(M_im).max()))
            y_re, y_im = cmatmul(AT_RE, AT_IM, M_re, M_im)
            Y16_re, _ = cmatmul(y_re, y_im, A_RE, A_IM)
            emp["Y16"] = max(emp["Y16"], int(np.abs(Y16_re).max()))

    rows = [
        ("d (int8)",        128,        128),
        ("V_re",            emp["V_re"], vre_wc),
        ("V_im",            emp["V_im"], vim_wc),
        ("a_operand(B-port)", emp["a_op"], a_wc),
        ("w_operand(A-port)", wop_max,   wop_max),
        ("DSP product k",   None,        k_wc),
        ("M_re (acc)",      emp["M_re"], m_wc),
        ("M_im (acc)",      emp["M_im"], m_wc),
        ("Y16 (out xform)", emp["Y16"],  25 * m_wc // 8),  # 느슨한 상한
    ]
    print(f"    {'stage':18s} {'empirical':>12s} {'theory(±128)':>14s}  RTL폭(theory)")
    for name, e, t in rows:
        es = "-" if e is None else f"{e:>12d}"
        print(f"    {name:18s} {es} {t:>14d}   → {_sbits(t):2d}-bit signed")
    print("    (RTL 은 theory 기준 폭 + 여유로 사이징 → 어떤 int8 입력도 overflow 없음)")


# =============================================================================
# 8.  RTL emit — wino_input_transform.v / wino_output_transform.v (곱셈기 0개)
# =============================================================================
RTL_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "RTL", "conv2_winograd"))

# RTL datapath 폭 — relu 입력(d∈[0,127], =relu(conv1)) 이론 worst-case + 1-bit margin.
#   (relu_bounds() 산출: t=508 V/a=4064 w=786 k=3.19M M=4.55M y/Y16=45.7M)
#   ±128 가정 대신 입력 보장범위로 좁힘 → LUT 절감. overflow 없음(삼각부등식 상한).
DW = 8     # d (int8, relu → 0..127)
TW = 11    # t = Bᵀd 중간값 (≤508)
VW = 14    # V_re/V_im, activation operand B-port (≤4064)
UW = 12    # U weight operand A-port (실 weight ≤786)
PW = 24    # DSP product k (≤3.19M)
MW = 25    # M accumulator (≤4.55M, cross-lane/8-IC 합 포함)
YW = 28    # Y16 / output transform 중간 y (≤45.7M)


def _term(coeff, var):
    """coeff*var 를 Verilog 항으로 (coeff ∈ {0,±1,±2,±4,...})."""
    if coeff == 0:
        return None
    a = abs(coeff)
    if a == 1:
        t = var
    elif (a & (a - 1)) == 0:                 # power of 2 → arithmetic shift
        t = f"({var} <<< {a.bit_length() - 1})"
    else:
        t = f"({a} * {var})"                  # (이 행렬엔 없음)
    return ("-" if coeff < 0 else "+", t)


def _lincomb(terms, width):
    """terms=[(coeff,var)] → signed Verilog 식. 전부 0 이면 sized 0."""
    parts = [p for p in (_term(c, v) for c, v in terms) if p]
    if not parts:
        return f"{width}'sd0"
    s0, t0 = parts[0]
    expr = (t0 if s0 == "+" else f"-{t0}")
    for s, t in parts[1:]:
        expr += f" {s} {t}"
    return expr


def emit_input_transform():
    """d(6×6 int8) → 46 activation operand (V=BᵀdB, 곱셈기 0개)."""
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//" + "/" * 78)
    L.append("// wino_input_transform.v  (자동생성: scripts/weights/winograd_gen.py)")
    L.append("//   복소수 Winograd F(4,3) 입력변환  V = Bᵀ·d·B  (per IC, 곱셈기 0개)")
    L.append("//   d(6×6 INT8) → 46 activation operand (B-port feed), canonical 순서:")
    L.append("//     [16 real pos: V_re] + [10 cmul pos: (V_re+V_im), V_re, V_im]")
    L.append("//   2-stage: t=Bᵀ·d (계수 {0,±1,±4}) → V=t·B (계수 {0,±1,±4}). add/shift/neg only.")
    L.append("//" + "/" * 78)
    L.append(f"module wino_input_transform #(parameter DW={DW}, VW={VW}) (")
    L.append("    input  wire [36*DW-1:0] d_flat,   // d[k][l] = d_flat[(k*6+l)*DW +: DW] (signed)")
    L.append("    output wire [46*VW-1:0] a_flat    // operand i = a_flat[i*VW +: VW] (signed)")
    L.append(");")
    # unpack d
    L.append(f"    wire signed [{TW-1}:0] d [0:5][0:5];")
    L.append("    genvar gk, gl;")
    L.append("    generate for (gk=0; gk<6; gk=gk+1) for (gl=0; gl<6; gl=gl+1)")
    L.append("        assign d[gk][gl] = $signed(d_flat[(gk*6+gl)*DW +: DW]);")
    L.append("    endgenerate")
    L.append("")
    # stage 1: t_re[p][l], t_im[p][l]
    L.append(f"    // stage1: t = Bᵀ·d   t[p][l] = Σ_k Bᵀ[p,k]·d[k][l]")
    L.append(f"    wire signed [{TW-1}:0] tre [0:5][0:5];")
    L.append(f"    wire signed [{TW-1}:0] tim [0:5][0:5];")
    for p in range(6):
        for l in range(6):
            tre = [(int(BT_RE[p, k]), f"d[{k}][{l}]") for k in range(6)]
            tim = [(int(BT_IM[p, k]), f"d[{k}][{l}]") for k in range(6)]
            L.append(f"    assign tre[{p}][{l}] = {_lincomb(tre, TW)};")
            L.append(f"    assign tim[{p}][{l}] = {_lincomb(tim, TW)};")
    L.append("")
    # stage 2: V at needed positions (26 V_re + 10 V_im)
    L.append(f"    // stage2: V = t·B   V[p][q] = Σ_l t[p][l]·Bᵀ[q,l]   (B[l][q]=Bᵀ[q,l])")
    needed_vre = sorted(set(REAL_POS) | set(CMUL_POS))
    needed_vim = sorted(set(CMUL_POS))
    for (p, q) in needed_vre:
        # V_re[p][q] = Σ_l (tre[p][l]*BT_RE[q,l] - tim[p][l]*BT_IM[q,l])
        terms = []
        for l in range(6):
            terms.append((int(BT_RE[q, l]), f"tre[{p}][{l}]"))
            terms.append((-int(BT_IM[q, l]), f"tim[{p}][{l}]"))
        L.append(f"    wire signed [{VW-1}:0] vre_{p}_{q} = {_lincomb(terms, VW)};")
    for (p, q) in needed_vim:
        # V_im[p][q] = Σ_l (tre[p][l]*BT_IM[q,l] + tim[p][l]*BT_RE[q,l])
        terms = []
        for l in range(6):
            terms.append((int(BT_IM[q, l]), f"tre[{p}][{l}]"))
            terms.append((int(BT_RE[q, l]), f"tim[{p}][{l}]"))
        L.append(f"    wire signed [{VW-1}:0] vim_{p}_{q} = {_lincomb(terms, VW)};")
    L.append("")
    # operands assembly (canonical order)
    L.append("    // 46 activation operand (canonical 순서 = weight operand 와 동일)")
    idx = 0
    for (p, q) in REAL_POS:
        L.append(f"    assign a_flat[{idx}*VW +: VW] = vre_{p}_{q};  // real ({p},{q}) V_re")
        idx += 1
    for (p, q) in CMUL_POS:
        L.append(f"    assign a_flat[{idx}*VW +: VW] = vre_{p}_{q} + vim_{p}_{q};  // cmul ({p},{q}) c+d")
        idx += 1
        L.append(f"    assign a_flat[{idx}*VW +: VW] = vre_{p}_{q};  // cmul ({p},{q}) c")
        idx += 1
        L.append(f"    assign a_flat[{idx}*VW +: VW] = vim_{p}_{q};  // cmul ({p},{q}) d")
        idx += 1
    assert idx == 46
    L.append("endmodule")
    return "\n".join(L) + "\n"


def emit_output_transform():
    """6×6 complex M → 4×4 real Y16 (Y16=Aᵀ·M·A, 곱셈기 0개, 계수 {0,±1})."""
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//" + "/" * 78)
    L.append("// wino_output_transform.v  (자동생성: scripts/weights/winograd_gen.py)")
    L.append("//   복소수 Winograd F(4,3) 출력변환  Y16 = Aᵀ·M·A  (per OC,tile, 곱셈기 0개)")
    L.append("//   M(6×6 complex, 켤레 포함 전체) → Y16(4×4 real). imag 은 수학적으로 0.")
    L.append("//   2-stage: y=Aᵀ·M (계수 {0,±1}) → Y16=y·A (계수 {0,±1}). add/sub/neg only.")
    L.append("//   out = sat(Y16>>>14)+ReLU 은 wino_truncate 에서 (= direct conv bit-exact).")
    L.append("//" + "/" * 78)
    L.append(f"module wino_output_transform #(parameter MW={MW}, YW={YW}) (")
    L.append("    input  wire [36*MW-1:0] mre_flat,  // M_re[p][q] = [(p*6+q)*MW +: MW] (signed)")
    L.append("    input  wire [36*MW-1:0] mim_flat,  // M_im[p][q]")
    L.append("    output wire [16*YW-1:0] y16_flat   // Y16[i][j] = [(i*4+j)*YW +: YW] (signed, real)")
    L.append(");")
    L.append(f"    wire signed [{MW-1}:0] mre [0:5][0:5];")
    L.append(f"    wire signed [{MW-1}:0] mim [0:5][0:5];")
    L.append("    genvar gp, gq;")
    L.append("    generate for (gp=0; gp<6; gp=gp+1) for (gq=0; gq<6; gq=gq+1) begin")
    L.append("        assign mre[gp][gq] = $signed(mre_flat[(gp*6+gq)*MW +: MW]);")
    L.append("        assign mim[gp][gq] = $signed(mim_flat[(gp*6+gq)*MW +: MW]);")
    L.append("    end endgenerate")
    L.append("")
    # stage 1: y[i][l] = Σ_p Aᵀ[i,p]·M[p][l]  (i 0..3, l 0..5)  complex
    L.append("    // stage1: y = Aᵀ·M   y[i][l] = Σ_p Aᵀ[i,p]·M[p][l]")
    L.append(f"    wire signed [{YW-1}:0] yre [0:3][0:5];")
    L.append(f"    wire signed [{YW-1}:0] yim [0:3][0:5];")
    for i in range(4):
        for l in range(6):
            yre = []
            yim = []
            for p in range(6):
                # (AT_RE+jAT_IM)[i,p] * (mre+j mim)[p][l]
                yre.append((int(AT_RE[i, p]), f"mre[{p}][{l}]"))
                yre.append((-int(AT_IM[i, p]), f"mim[{p}][{l}]"))
                yim.append((int(AT_RE[i, p]), f"mim[{p}][{l}]"))
                yim.append((int(AT_IM[i, p]), f"mre[{p}][{l}]"))
            L.append(f"    assign yre[{i}][{l}] = {_lincomb(yre, YW)};")
            L.append(f"    assign yim[{i}][{l}] = {_lincomb(yim, YW)};")
    L.append("")
    # stage 2: Y16[i][j] = Σ_l y[i][l]·A[l][j] = Σ_l y[i][l]·Aᵀ[j,l]  (real part only)
    L.append("    // stage2: Y16 = y·A   Y16[i][j] = Σ_l y[i][l]·Aᵀ[j,l]  (real part, imag=0)")
    for i in range(4):
        for j in range(4):
            terms = []
            for l in range(6):
                # Re( (yre+j yim)·(AT_RE[j,l]+j AT_IM[j,l]) ) = yre*AT_RE - yim*AT_IM
                terms.append((int(AT_RE[j, l]), f"yre[{i}][{l}]"))
                terms.append((-int(AT_IM[j, l]), f"yim[{i}][{l}]"))
            L.append(f"    assign y16_flat[{i*4+j}*YW +: YW] = {_lincomb(terms, YW)};")
    L.append("endmodule")
    return "\n".join(L) + "\n"


def emit_lane_reduce():
    """한 lane 의 46 DSP product → 26 partial (re/im). Gauss + real passthrough."""
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//" + "/" * 78)
    L.append("// wino_lane_reduce.v  (자동생성: scripts/weights/winograd_gen.py)")
    L.append("//   1 lane(=1 IC) 의 46 DSP product → 26 position partial (re/im).")
    L.append("//   operand 0..15  = real pos: pre=prod, pim=0.")
    L.append("//   operand 16..   = cmul pos (10×3, Gauss): k1=prod[+0],k2=prod[+1],k3=prod[+2]")
    L.append("//                    pre = k1-k3,  pim = k1+k2.")
    L.append("//" + "/" * 78)
    L.append(f"module wino_lane_reduce #(parameter PW={PW}, MW={MW}) (")
    L.append("    input  wire [46*PW-1:0] prod_flat,  // prod i = [i*PW +: PW] (signed)")
    L.append("    output wire [26*MW-1:0] pre_flat,   // partial re, pos k = [k*MW +: MW]")
    L.append("    output wire [26*MW-1:0] pim_flat    // partial im")
    L.append(");")
    L.append(f"    wire signed [PW-1:0] prod [0:45];")
    L.append("    genvar gi;")
    L.append("    generate for (gi=0; gi<46; gi=gi+1)")
    L.append("        assign prod[gi] = $signed(prod_flat[gi*PW +: PW]);")
    L.append("    endgenerate")
    L.append("")
    L.append("    // real positions (operand 0..15)")
    for k in range(16):
        L.append(f"    assign pre_flat[{k}*MW +: MW] = prod[{k}];")
        L.append(f"    assign pim_flat[{k}*MW +: MW] = {MW}'sd0;")
    L.append("    // cmul positions (operand 16.., Gauss)")
    for j in range(10):
        k = 16 + j
        b = 16 + 3 * j
        L.append(f"    assign pre_flat[{k}*MW +: MW] = prod[{b}] - prod[{b+2}];  // k1-k3  cmul {CMUL_POS[j]}")
        L.append(f"    assign pim_flat[{k}*MW +: MW] = prod[{b}] + prod[{b+1}];  // k1+k2")
    L.append("endmodule")
    return "\n".join(L) + "\n"


def emit_m_assemble():
    """26 Msum(re/im) → 36 M(re/im), 켤레유도 포함 (full 6×6)."""
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//" + "/" * 78)
    L.append("// wino_m_assemble.v  (자동생성: scripts/weights/winograd_gen.py)")
    L.append("//   26 계산 position(Msum) → 36 full M(6×6). 켤레유도: M[der]=conj(M[rep]).")
    L.append("//   Msum index: 0..15 = REAL_POS, 16..25 = CMUL_POS.")
    L.append("//" + "/" * 78)
    L.append(f"module wino_m_assemble #(parameter MW={MW}) (")
    L.append("    input  wire [26*MW-1:0] sre_flat,  // Msum re, idx k = [k*MW +: MW]")
    L.append("    input  wire [26*MW-1:0] sim_flat,  // Msum im")
    L.append("    output wire [36*MW-1:0] mre_flat,  // M[p][q] = [(p*6+q)*MW +: MW]")
    L.append("    output wire [36*MW-1:0] mim_flat")
    L.append(");")
    L.append("    wire signed [MW-1:0] sre [0:25];")
    L.append("    wire signed [MW-1:0] sim [0:25];")
    L.append("    genvar gk;")
    L.append("    generate for (gk=0; gk<26; gk=gk+1) begin")
    L.append("        assign sre[gk] = $signed(sre_flat[gk*MW +: MW]);")
    L.append("        assign sim[gk] = $signed(sim_flat[gk*MW +: MW]);")
    L.append("    end endgenerate")
    L.append("")
    for p in range(6):
        for q in range(6):
            k = p * 6 + q
            if (p, q) in REAL_POS:
                idx = REAL_POS.index((p, q))
                L.append(f"    assign mre_flat[{k}*MW +: MW] = sre[{idx}];   // ({p},{q}) real")
                L.append(f"    assign mim_flat[{k}*MW +: MW] = {MW}'sd0;")
            elif (p, q) in CMUL_POS:
                idx = 16 + CMUL_POS.index((p, q))
                L.append(f"    assign mre_flat[{k}*MW +: MW] = sre[{idx}];   // ({p},{q}) cmul")
                L.append(f"    assign mim_flat[{k}*MW +: MW] = sim[{idx}];")
            else:
                rep = CONJ_MAP[(p, q)]
                idx = 16 + CMUL_POS.index(rep)
                L.append(f"    assign mre_flat[{k}*MW +: MW] =  sre[{idx}];  // ({p},{q}) conj of {rep}")
                L.append(f"    assign mim_flat[{k}*MW +: MW] = -sim[{idx}];")
    L.append("endmodule")
    return "\n".join(L) + "\n"


def emit_weight_rom(U_re, U_im):
    """U weight 를 baked 상수 ROM 으로. sel=oc*2+grp(0..31) → 184 operand(2576-bit).
       lane L (grp g) = IC(g*4+L). operand i 는 lane-major: [(L*46+i)*UW +: UW].
       engine 의 V-bank 선택(lane L act = V-bank[g*4+L]) 과 정렬되어야 함."""
    WORD = 4 * 46 * UW   # 2576
    mask = (1 << UW) - 1
    L = []
    L.append("`timescale 1ns / 1ps")
    L.append("//" + "/" * 78)
    L.append("// wino_weight_rom.v  (자동생성: scripts/weights/winograd_gen.py)")
    L.append("//   U = G·g·Gᵀ 사전계산 weight 의 baked 상수 ROM (PS write 없음 — fixed model).")
    L.append("//   sel = oc*2 + grp (0..31).  out w_flat = 4 lane × 46 operand (lane-major).")
    L.append("//     lane L (grp g) = IC(g*4+L).  operand i = w_flat[(L*46+i)*UW +: UW] (signed).")
    L.append("//     operand 순서 = [16 real: U_re] + [10 cmul: a, b-a, a+b] (input transform 과 정렬).")
    L.append(f"//   조합 ROM (32 entry × {WORD}-bit). 200MHz 시 register/pipeline 검토(§timing).")
    L.append("//" + "/" * 78)
    L.append(f"module wino_weight_rom #(parameter UW={UW}) (")
    L.append("    input  wire [4:0]         sel,    // oc*2 + grp")
    L.append(f"    output reg  [4*46*UW-1:0] w_flat")
    L.append(");")
    L.append("    always @(*) begin")
    L.append("        case (sel)")
    for sel in range(32):
        oc = sel >> 1
        grp = sel & 1
        word = 0
        for lane in range(4):
            ic = grp * 4 + lane
            ops = weight_operands(U_re, U_im, oc, ic)
            for i, v in enumerate(ops):
                k = lane * 46 + i
                word |= (int(v) & mask) << (k * UW)
        ndig = (WORD + 3) // 4
        L.append(f"            5'd{sel:<2d}: w_flat = {WORD}'h{word:0{ndig}x};  // oc={oc} grp={grp} (IC {grp*4}..{grp*4+3})")
    L.append(f"            default: w_flat = {WORD}'d0;")
    L.append("        endcase")
    L.append("    end")
    L.append("endmodule")
    return "\n".join(L) + "\n"


def emit_weight_hex(U_re, U_im):
    """pre-transformed U weight → PS-writable narrow BMG hex/header (ROM 대체).
       layout = emit_weight_rom 과 동일 operand 순서 → loader 가 wmem[sel] 조립 시
       wmem[sel] == 옛 ROM[sel] (bit-identical) → mul array 동작 불변.
         narrow_addr = sel*184 + (lane*46 + i),  sel=oc*2+grp, lane 0..3, i 0..45.
         word[11:0] = operand (UW=12 2's-comp), 상위 0 (loader 가 [UW-1:0] 만 사용).
       32 entry × 184 operand = 5888 word (32-bit each)."""
    os.makedirs(TBDATA_DIR, exist_ok=True)
    mask = (1 << UW) - 1
    words = []
    for sel in range(32):
        oc, grp = sel >> 1, sel & 1
        for lane in range(4):
            ic = grp * 4 + lane
            ops = weight_operands(U_re, U_im, oc, ic)   # 46 operand (real16 + cmul10×3)
            for v in ops:
                words.append(int(v) & mask)
    assert len(words) == 32 * 184, len(words)
    # .hex (TB $readmemh, 32-bit word)
    with open(os.path.join(TBDATA_DIR, "winograd_u.hex"), "w") as f:
        f.write("\n".join(format(w, "08x") for w in words) + "\n")
    # .h (vitis firmware: PS 가 narrow BMG 에 순차 write)
    hdr = ["// 자동생성: scripts/weights/winograd_gen.py  (pre-transformed Winograd U weight)",
           "// PS 가 conv2 winograd weight BMG(32-bit×8192, 5888 used)에 addr 0..5887 순차 write.",
           f"#define CONV2_WINO_WEIGHT_COUNT {len(words)}",
           f"#define CONV2_WINO_UW {UW}",
           "static const unsigned int conv2_winograd_weights[CONV2_WINO_WEIGHT_COUNT] = {"]
    for i in range(0, len(words), 8):
        hdr.append("    " + ", ".join(f"0x{w:08x}" for w in words[i:i + 8]) + ",")
    hdr.append("};")
    with open(os.path.join(TBDATA_DIR, "conv2_winograd_weights.h"), "w") as f:
        f.write("\n".join(hdr) + "\n")
    print(f"  emit  data/winograd/winograd_u.hex + conv2_winograd_weights.h  ({len(words)} word)")


def emit_truncate_vectors(nt=4000):
    """wino_truncate 검증: 랜덤 Y16 → out = clip(Y16>>>14, 0, 127) (relu+sat, 기존 truncate_relu 의미)."""
    os.makedirs(TBDATA_DIR, exist_ok=True)
    rng = np.random.RandomState(99260604)
    # ±2^21 → >>14 후 ±128 부근 → sat 양/음 모두 자극
    Y16 = rng.randint(-(1 << 21), (1 << 21), size=nt).astype(np.int64)
    out = np.clip(Y16 >> OUT_SHIFT, 0, 127).astype(np.int64)   # arithmetic shift + relu+sat
    with open(os.path.join(TBDATA_DIR, "tr_y16.hex"), "w") as f:
        f.write("\n".join(_hexcol(Y16, YW)) + "\n")
    with open(os.path.join(TBDATA_DIR, "tr_out.hex"), "w") as f:
        f.write("\n".join(_hexcol(out, 8)) + "\n")
    print(f"  emit  data/winograd/tr_{{y16,out}}.hex  (nt={nt})")


def emit_rtl(U_re, U_im):
    os.makedirs(RTL_DIR, exist_ok=True)
    for fname, content in [
        ("wino_input_transform.v", emit_input_transform()),
        ("wino_output_transform.v", emit_output_transform()),
        ("wino_lane_reduce.v", emit_lane_reduce()),
        ("wino_m_assemble.v", emit_m_assemble()),
        # weight = PS-writable BMG+loader (winograd_u.hex/.h) → ROM 제거 (emit_weight_hex).
    ]:
        path = os.path.join(RTL_DIR, fname)
        with open(path, "w") as f:
            f.write(content)
        print(f"  emit  {os.path.relpath(path, os.path.join(HERE, '..', '..'))}  ({content.count(chr(10))} lines)")


TBDATA_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "data", "winograd"))


def _hexcol(arr, width_bits):
    """flat int array → 2's-complement hex 문자열 리스트 (한 줄 1값)."""
    mask = (1 << width_bits) - 1
    ndig = (width_bits + 3) // 4
    return [format(int(v) & mask, f"0{ndig}x") for v in np.asarray(arr).reshape(-1)]


def emit_test_vectors(nt=2000):
    """hw_model(=golden) 로 transform 단위검증용 벡터 생성 (deterministic)."""
    os.makedirs(TBDATA_DIR, exist_ok=True)
    rng = np.random.RandomState(20260604)

    # ---- input transform: random d∈[0,127] (relu 범위 — 폭이 이 범위로 사이징됨) → 46 op ----
    d = rng.randint(0, 128, size=(nt, 6, 6)).astype(np.int64)
    Vr, Vi = input_transform(d)
    a = activation_operands(Vr, Vi)                  # (nt,46)
    with open(os.path.join(TBDATA_DIR, "it_d.hex"), "w") as f:
        f.write("\n".join(_hexcol(d, DW)) + "\n")    # nt*36 lines, 8-bit
    with open(os.path.join(TBDATA_DIR, "it_a.hex"), "w") as f:
        f.write("\n".join(_hexcol(a, VW)) + "\n")     # nt*46 lines, 16-bit

    # ---- output transform: random M (±2^22 ≈ 실 M 최대 4.5M 근처) → 16 Y16 (real) ----
    Mre = rng.randint(-(1 << 22), (1 << 22), size=(nt, 6, 6)).astype(np.int64)
    Mim = rng.randint(-(1 << 22), (1 << 22), size=(nt, 6, 6)).astype(np.int64)
    Yr, Yi = output_transform(Mre, Mim)              # (nt,4,4)
    with open(os.path.join(TBDATA_DIR, "ot_mre.hex"), "w") as f:
        f.write("\n".join(_hexcol(Mre, MW)) + "\n")   # nt*36 lines, 32-bit
    with open(os.path.join(TBDATA_DIR, "ot_mim.hex"), "w") as f:
        f.write("\n".join(_hexcol(Mim, MW)) + "\n")
    with open(os.path.join(TBDATA_DIR, "ot_y16.hex"), "w") as f:
        f.write("\n".join(_hexcol(Yr, YW)) + "\n")    # nt*16 lines, 36-bit
    print(f"  emit  data/winograd/{{it_d,it_a,ot_mre,ot_mim,ot_y16}}.hex  (nt={nt})")


def emit_mul_array_vectors(U_re, U_im, nt=1000):
    """mul array 단위검증 벡터: 실 U weight × [0,127] tile activation → M (hw_model)."""
    os.makedirs(TBDATA_DIR, exist_ok=True)
    rng = np.random.RandomState(70260604)
    w_all = np.empty((nt, 8, 46), dtype=np.int64)   # 8 IC weight operand
    a_all = np.empty((nt, 8, 46), dtype=np.int64)   # 8 IC activation operand
    mre_all = np.empty((nt, 36), dtype=np.int64)
    mim_all = np.empty((nt, 36), dtype=np.int64)
    for t in range(nt):
        oc = t % 16
        for ic in range(8):
            w_all[t, ic] = weight_operands(U_re, U_im, oc, ic)
            d = rng.randint(0, 128, size=(6, 6)).astype(np.int64)   # relu range
            Vr, Vi = input_transform(d)
            a_all[t, ic] = activation_operands(Vr, Vi)
        M_re, M_im = mul_array_M(w_all[t], a_all[t])
        mre_all[t] = M_re.reshape(-1)
        mim_all[t] = M_im.reshape(-1)
    with open(os.path.join(TBDATA_DIR, "ma_w.hex"), "w") as f:
        f.write("\n".join(_hexcol(w_all, UW)) + "\n")    # nt*8*46, 14-bit
    with open(os.path.join(TBDATA_DIR, "ma_a.hex"), "w") as f:
        f.write("\n".join(_hexcol(a_all, VW)) + "\n")     # nt*8*46, 16-bit
    with open(os.path.join(TBDATA_DIR, "ma_mre.hex"), "w") as f:
        f.write("\n".join(_hexcol(mre_all, MW)) + "\n")   # nt*36, 32-bit
    with open(os.path.join(TBDATA_DIR, "ma_mim.hex"), "w") as f:
        f.write("\n".join(_hexcol(mim_all, MW)) + "\n")
    print(f"  emit  data/winograd/ma_{{w,a,mre,mim}}.hex  (nt={nt})")


def print_layout():
    print("\n[D] 46-operand layout / 26-position / 켤레 map (RTL 구조 참조)")
    print(f"    REAL_POS (16, op 0..15, weight=U_re / act=V_re):")
    print(f"      {REAL_POS}")
    print(f"    CMUL_POS (10, op 16.. 각 3개 [a|b-a|a+b]×[c+d|c|d], Gauss):")
    print(f"      {CMUL_POS}")
    print(f"    CONJ_MAP (10 derived ← rep, M[der]=conj(M[rep])):")
    for der, rep in sorted(CONJ_MAP.items()):
        print(f"      M{der} = conj(M{rep})")
    print(f"    RTL 폭: DW={DW} TW={TW} VW={VW} UW={UW} MW={MW} YW={YW}")


def load_golden_module():
    path = os.path.join(GOLDEN_DIR, "1_complex_winograd_f(4,3).py")
    spec = importlib.util.spec_from_file_location("golden_wino", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def assert_matrices_match(g):
    for name, mine, theirs in [
        ("G_RE", G_RE, g.G_RE), ("G_IM", G_IM, g.G_IM),
        ("BT_RE", BT_RE, g.BT_RE), ("BT_IM", BT_IM, g.BT_IM),
        ("AT_RE", AT_RE, g.AT_RE), ("AT_IM", AT_IM, g.AT_IM),
    ]:
        assert np.array_equal(mine, theirs), f"matrix {name} != golden"
    print("  [matrix] generator 행렬 == golden §9.1 정정판  ✓")


# =============================================================================
# 7.  메인 — hw_model vs golden bit-exact + bit-width 리포트
# =============================================================================
def main():
    N_LIMIT = int(os.environ.get("WINO_N", "0")) or None
    print("=" * 70)
    print("winograd_gen — hw-model (RTL 데이터패스) vs golden bit-exact 검증")
    print("=" * 70)

    g = load_golden_module()
    assert_matrices_match(g)

    data = rc.load_assignment_data(data_dir=DATA_DIR)
    images_full = data["input"]; w2 = data["w2"]; expected_full = data["output"]
    w1, wfc = data["w1"], data["wfc"]

    # conv1 → relu → f1 (conv2 입력, int8 ∈ [0,127]) — 전체 이미지 (bit-width 분석용)
    conv1 = rc.Conv2D_Spec(w1, shift=10)
    f1_full = rc.ReLU()(conv1(images_full)).astype(np.int8)

    # 정확도 검증은 N_LIMIT 으로 제한 (per-image Python loop 가 느림)
    if N_LIMIT:
        f1, expected = f1_full[:N_LIMIT], expected_full[:N_LIMIT]
    else:
        f1, expected = f1_full, expected_full
    N = f1.shape[0]
    print(f"  N={N} (정확도)  /  {f1_full.shape[0]} (bit-width)   w2={w2.shape}")
    print(f"  f1 range = [{f1_full.min()}, {f1_full.max()}]  (relu → ≥0)")

    U_re, U_im = compute_U(w2)
    g_golden = g.Conv2D_WinogradComplexF43(w2, shift=10)

    # ---- (A) hw_model == golden conv2 winograd (bit-exact) ----
    print("\n[A] hw_model conv2 vs golden conv2_wino (bit-exact)")
    stats = Stats()
    f2_hw = hw_forward(f1, U_re, U_im, stats)
    f2_g = g_golden(f1)
    match = (f2_hw == f2_g)
    rate = float(match.mean())
    print(f"  hw_model == golden : {rate*100:.4f}%  "
          f"{'PASS ✅' if rate == 1.0 else 'FAIL ❌'}")
    if rate < 1.0:
        for b in np.argwhere(~match)[:5]:
            n, oc, r, c = b
            print(f"    MM (n={n},oc={oc},r={r},c={c}): hw={f2_hw[tuple(b)]} g={f2_g[tuple(b)]}")

    # ---- (B) 전체 pipeline logit == output.npy ----
    print("\n[B] 전체 pipeline (hw conv2) logit vs output.npy")
    relu, pool, flat = rc.ReLU(), rc.MaxPool2x2(), rc.FlattenCHW()
    fc = rc.FC_Spec(wfc, shift=10)
    logit = fc(flat(pool(relu(f2_hw).astype(np.int8))))
    m = rc.bit_exact_match(logit, expected)
    print(f"  per-image match : {m['image_match_rate']*100:.4f}%  (target 100)")

    # ---- (C) bit-width 리포트 (전체 이미지 + 이론 worst-case) ----
    bitwidth_report(f1_full, U_re, U_im)
    relu_bounds(U_re, U_im, margin=1)

    # ---- (D) layout + (E) RTL emit ----
    print_layout()
    print("\n[E] RTL emit → RTL/conv2_winograd/")
    emit_rtl(U_re, U_im)
    print("\n[F] 단위검증 벡터 → data/winograd/")
    emit_test_vectors()
    emit_mul_array_vectors(U_re, U_im)
    emit_truncate_vectors()
    print("\n[G] pre-transformed U weight (PS BMG hex/header) → data/winograd/")
    emit_weight_hex(U_re, U_im)
    print("=" * 70)


if __name__ == "__main__":
    main()
