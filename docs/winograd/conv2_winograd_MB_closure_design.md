# conv2 Winograd 200MHz — M·B 두 벽 동시 닫기 설계 (코드 전 설계서)

> 대상 = `vivado_reports/06_route_wns-0.094_MBD-baseline` (현재 RTL=revert 후 이 상태).
> 원칙: **벽 성질에 레버 매칭** + **이전 실패 모드를 구조적으로 회피**.
> 검증 gate = standalone `tb_conv2_winograd_engine_multi` → full `tb_cnn_accelerator_winograd_multi`.
> 관련: `conv2_winograd_engine_arch.md`(anchor §2.1, 안전수정 §5), `timing_review.md`(레버 프레임 §2/§6).
>
> **✅ 결정·결과 (2026-06-15)**: M = **carry-bisect**(§2 의 carry-select 아님 — 사용자 선택, +1 lat),
> B = **floorplan-only**(§4-2 권장안, 미적용). M 적용 완료: M 경로 im 25-bit add 를 13+12 분할
> (★`car_n` 2-bit: `-sim` low `~a+~b+2` 가 2¹⁴ 도달 → hi 로 carry 2 가능 — standalone 이 먼저 잡음),
> standalone+full iverilog **100/100**, **1348→1349 cyc/img**, m_valid issue+11→**+12** / tag→**16** /
> collector `tg_*[16]` (arch §2.1, journey Iter 14). **다음 = B floorplan(§1) + route 로 M·B 동시 확인.**
> (아래 §2 carry-select 는 **미채택 대안**으로 보존 — bisect 가 route 에서 LUT/WNS 실패 시 fallback.)

## 0. 두 벽 (report 확정, 레버 매칭)

| 벽 | 경로 | logic/net | fo | 정체 | 레버 |
|---|---|---|---|---|---|
| **M** (−0.094) | `gpim_q→m_im_flat` | **58/42** | **2** | 25-bit `-(acc+gp)` carry chain (7×CARRY4) | **연산구조**(adder) |
| **D** (−0.037) | `gpab→gpim_q` | 42/58 | 2 | 25-bit plain add (6×CARRY4) | M 과 동류 |
| **B** (−0.088) | `tile6_q·grp_q→u_it/tre` | **32/68** | **8~11** | 입력변환 scatter (tile6_q→4 IT) | **floorplan**(배치) |

★ 핵심 사실: M 은 fo=2(fanout·congestion 무관) **순수 연산깊이** / B 는 net 68% **순수 배치**. → **서로 다른 레버, 서로 독립.** 한 번의 route 에 둘 다 반영.

---

## 1. B 벽 → **floorplan pblock** (XDC only, RTL 0 변경)

### 1.1 왜 floorplan (RTL 아님)
- B 는 `tile6_q`(2304b) 가 **4개 IT 로 흩어진 scatter**(net 68%, fo 8~11). IT 4개가 칩에 퍼져서 route 김.
- **class B(per-IT RTL 분할)가 −0.150 으로 regression** 한 이유 = placer 가 자유로워 배치를 churn. → RTL 로 net 벽 건드리면 whack-a-mole.
- **floorplan 은 배치를 *고정*** → churn 자체가 안 일어남. `timing_review §7`: *"200 확정은 floorplan 성패"*. `wino_mul_array.v:27` 에 `pb_laneN` 핸들 이미 존재. **미시도 레버.**

### 1.2 설계 (pblock 4 lane + 중앙 reduce)
- **lane pblock ×4**: `pb_lane[k] = { conv2/lane[k].u_mul + conv2/gic[k].u_it }` (IT[k] 와 그 lane 을 한 영역에). 각 pblock = 그 lane 의 ~46 DSP column 범위 + 인접 fabric.
  ```tcl
  create_pblock pb_lane0
  add_cells_to_pblock pb_lane0 [get_cells {*/conv2/lane[0].u_mul */conv2/gic[0].u_it}]
  resize_pblock pb_lane0 -add {SLICE_X..Y.. DSP48_X..Y..}   # DSP 열 기준 수직 슬라이스
  # lane1..3 동일
  ```
- **중앙 region**: 공유 reduce(gpab/gpcd/gpre/acc/msum/m_assemble/m_flat) + `tile6_q` + tag/collector → 4 lane pblock 의 중심에. (pblock 으로 묶거나 미지정 후 placer 자율.)
- 효과: IT[k] 가 lane[k] 옆에 고정 → ① `tile6_q→IT` route 단축(IT 압축), ② **배치 churn 정지**.

### 1.3 잔류 시 (floorplan 으로 부족하면) — 그때만 RTL
- `tile6_q` scatter 가 여전하면 **class B(per-IT `tile6_q_ic`) 재적용 + 그 register 를 lane pblock 안에 고정**. floorplan 이 churn 을 막으니 이번엔 regression 안 함. (RTL+XDC.)

### 1.4 검증
- **XDC only → bit-exact 자동**(배치만 바뀜, 로직 불변). iverilog 불필요. route → B 슬랙 확인.

---

## 2. M·D 벽 → **reduce adder carry-select** (latency-neutral, 정렬 0 변경)

### 2.1 왜 carry-select (bisect 아님)
- M·D = 25-bit add carry chain(6~7 CARRY4). 줄이는 법 = chain 분할.
- **bisect(+1 latency)는 tag/m_valid 재정렬이 필요했고 그게 0/100 실패의 원인.** → **재정렬 = 반복 위험.**
- **carry-select 는 latency 불변**(조합 adder 를 더 빠른 구조로만 교체) → **tag/collector/m_valid 재정렬 0** → 그 실패 모드 원천 차단. 같은 함수·같은 latency → **bit-exact 자명.**
- 비용: +LUT(high-half ×2 + mux). M 경로는 fo=2·net 42% 로 **reduce-local**(혼잡한 IT 영역 아님) → 국소 +LUT 수용 가능(현 LUT 76%).

### 2.2 설계 (노출된 25-bit add 2개를 carry-select)
대상 = grp1 cycle 의 `msum=acc+gpre_q`(→m_assemble→m_flat) + `gpre/gpim=gpab+gpcd`(→gpre_q). 13/12 분할:
```
{c_lo, s[12:0]} = a[12:0] + b[12:0]                       # 13-bit, 4 CARRY4
s_hi0          = a[24:13] + b[24:13]                      # carry=0 가정
s_hi1          = a[24:13] + b[24:13] + 1                  # carry=1 가정  (병렬)
s[24:13]       = c_lo ? s_hi1 : s_hi0                     # mux (1 LUT)
```
critical = max(13-bit carry, hi 병렬) + mux ≈ **~4 CARRY4 + mux** (옛 7). logic 2.85→~1.6ns → +net 2.09 = ~3.7 < 4.85 **닫힘.**
- **conj negate fold**: m_im[conj] = `-(acc+gp)` = `~acc+~gp+2` 도 동일 carry-select(입력반전+상수2). m_assemble 의 sign 을 engine m-계산으로 inline(=msum+m_assemble 합쳐 직접 carry-select m 산출). latency 불변.
- 구현 위치: `conv2_winograd_engine.v` g_msum + m latch (hand-code). m_assemble 은 routing 만 남김/흡수.

### 2.3 검증 (★standalone 먼저 — 이전 교훈)
- carry-select 는 **같은 함수·같은 latency** 라 bit-exact 자명하지만, Verilog 구조 오류(분할 index·sign) 가능 → **`tb_conv2_winograd_engine_multi` standalone 100/100 먼저**(reduce-tail 단독 격리, full-pipe 0/100 원인불명 회피) → full 100/100.

---

## 3. 순서 · 반복방지

| 단계 | 작업 | 변경 | 검증 |
|---|---|---|---|
| 1 | **M·D carry-select** (engine reduce) | RTL | standalone→full iverilog 100/100 |
| 2 | **B floorplan** (pblock XDC) | XDC | (iverilog 불필요) |
| 3 | 1+2 동시 route | — | WNS 확인 |
| 4 | B 잔류 시 §1.3 (class B in pblock) | RTL+XDC | iverilog 100/100 |

**왜 이전을 반복 안 하나:**
- M: carry-select = **latency-neutral → 재정렬 없음** (bisect 0/100 의 원인 제거). standalone-first.
- B: floorplan = **배치 고정 → churn 없음** (class B regression 의 원인 제거). XDC-only → 기능위험 0.
- 둘 다 **벽 성질에 맞는 레버** (M=연산→adder구조, B=배치→floorplan). 이전엔 net 벽에 RTL(class B)·logic 벽 fix 정렬오류였음.

## 4. ★ 결정 완료 (2026-06-15)
1. **M**: ~~carry-select~~ → **carry-bisect 채택**(+1 latency, −LUT). 사용자 선택 = "안전 refactor"
   (복사본 수정·standalone-first). 적용·검증 완료(상단 배너 / journey Iter 14). carry-select 는 §2 에 fallback 보존.
2. **B**: **floorplan-only 채택**(권장 시작, XDC). **미적용** — 다음 단계.
