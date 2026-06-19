# conv2 Winograd 200MHz — B·D 벽 floorplan 설계 (실측 배치 기반)

> # ❌ VERDICT (2026-06-19): 이 floorplan 접근은 **실패·기각**. 아래 설계는 *왜 안 되는지* 의 기록.
> **시도**: `pb_reduce`(reduce 압축) 1/3/4 CR 전부 **place 실패**(밀도: X1Y2=DSP열+lane LUT88%→slice158%;
> 글로벌 8FF/slice `Place 30-4`). hard+`skipUtilizationCheck`+`-unplace` 로 강제 place 하니 **WNS −1.116
> (10× 악화)**. **근본원인**: reduce 는 **흩어진 DSP-lane 4개에서 gather 하는 노드** → `gpim_q` 가 lane입력↔
> m_im출력 양쪽으로 찢김 → **−0.094 는 placer 의 최적 타협점**, 모으면(=이 설계) 입력쪽 route 폭발.
> 즉 **gather→central-reduce dataflow + 76% LUT 밀도 = floorplan 압축 intrinsic 불가**. → **다신 시도 금지.**
> 결산=`winograd_overclock_journey.md` Iter 15. 최종 = **171.43MHz**(VCO=1200, baseline). 아래는 설계 기록용 보존.

> 전제(당시): M 벽(−0.094)은 **carry-bisect 로 RTL 닫음**(journey Iter 14, ★이후 churn 으로 revert). 이 문서는
> **남은 B·D 벽**을 floorplan(XDC)으로 닫으려던 설계. 상위 = `conv2_winograd_MB_closure_design.md` §1.
> ★ 모든 좌표·경로는 **추측이 아니라** `vivado_reports/06_route_wns-0.094_MBD-baseline/wino_paths.rpt`
> (routed design, device **7a100t-csg324**)에서 실측한 값.

## 0. 실측 7 failing endpoint (route 06) 와 bisect 후 잔존

| # | slack | source → destination | logic/route | bisect 후 |
|---|---|---|---|---|
| 1 | −0.094 | `conv2/gpim_q_reg[25][4]` → `conv2/m_im_flat_reg[874]` | 2.851/2.091 (58/42) | **M → 닫힘** |
| 2 | −0.089 | `gpim_q[25][4]` → `m_im_flat[871]` | 58/42 | M → 닫힘 |
| 4 | −0.068 | `gpim_q[25][4]` → `m_im_flat[873]` | 58/42 | M → 닫힘 |
| 3 | −0.088 | `grp_q_reg_rep__75` → `gic[1].u_it/tre_reg[1][5][10]` | 1.617/**3.481 (68%)** | **B → 잔존(WNS)** |
| 6 | −0.032 | `tile6_q_reg[1916]` → `gic[3].u_it/tre_reg[2][5][10]` | 1.898/**3.092 (62%)** | **B → 잔존** |
| 7 | −0.023 | `tile6_q_reg[852]` → `gic[2].u_it/tre_reg[1][1][10]` | 1.898/**3.072 (62%)** | **B → 잔존** |
| 5 | −0.037 | `gpab_im_reg[20][1]` → `gpim_q_reg[20][23]` | 2.023/**2.812 (58%)** | **D → 잔존** |

→ M 3개가 bisect 로 닫히면 **WNS ≈ −0.088 (B 벽)**. 200MHz 닫기 = **B·D 의 route 단축**이 전부.

## 1. 실측 배치 geography (왜 route 가 긴가)

routed 06 의 실제 site (SLICE_XcolYrow):

| 블록 | 실측 위치 | 비고 |
|---|---|---|
| reduce (m_im_flat, u_asm, CARRY chain) | **X64–X65 / Y110–Y131** | M·D 누적. 이미 compact. |
| gpim_q / gpab (D source) | **X79–X83 / Y110** | reduce 옆이지만 X79→X64 = 15열 route |
| gic[3].u_it (IT lane3) | X58–X67 / Y89–95 | reduce 아래 |
| gic[1].u_it (IT lane1) | **X14–X30** / Y72–88 | **칩 왼쪽 절반** |
| gic[2].u_it (IT lane2) | **X14–X37** / Y109–113 | **칩 왼쪽 절반** |
| tile6_q (2304-bit reg) | **X14Y109, X58Y89, …(흩어짐)** | 4 IT 로 fan-out, 산개 |
| grp_q (d-mux→IT) | X30Y76 등 | IT 입력 |

**진단**: conv2 timing-core 가 **X14 ↔ X83 (칩 거의 전폭)** 로 smear. tile6_q·grp_q(producer)가
gic[1]/gic[2].u_it(왼쪽 X14–37) 와 reduce(오른쪽 X64–83) 양쪽으로 갈려 **16~23열 route**(=68% net).
**class B(tile6_q per-IT 분할)가 −0.150 으로 regression** 한 이유 = 이 산개를 placer 자유도로 더 키움.
→ **배치를 고정·압축**해야 함(floorplan). `timing_review §7`: *"200 확정은 floorplan 성패."*

## 2. 면적 현실 (왜 "작은 box" 불가, "core 만 pin")

`vivado_reports/01` synth hier: **conv2 = 32202 LUT(칩의 51%) / 41285 FF / 2219 SRL / 1472 LUTRAM / 184 DSP**.
- 32K LUT 전체를 작은 pblock 에 못 넣음(반칩 필요).
- 그러나 **2219 SRL + 1472 LUTRAM = lane 내부 per-PE weight RAM** → DSP 열에 붙어 **float 시켜야** 함.
- **timing-critical core = tile6_q + grp_q + 4 IT + gather/reduce(가산기 로직)** 는 LUT 가 작음
  → **이것만 ~2 clock region 으로 compact** 하면 B·D route 가 그 영역 안으로 짧아짐. lane/weight 는 자유.

## 3. 설계 — `pb_conv2_core` 1개 (timing subset 만 pin)

### 3.1 pin 대상 (core) — get_cells 패턴 (IP wrapper prefix = `*/cnn_accelerator_wino_0/inst/conv2/`)
| 그룹 | 패턴 |
|---|---|
| 4 input transform | `*/conv2/gic[*].u_it/*` (hierarchical) |
| tile→IT 입력 | `*/conv2/tile6_q_reg[*]`, `*/conv2/grp_q*` |
| gather | `*/conv2/gpab_*`, `*/conv2/gpcd_*`, `*/conv2/gpre_*`, `*/conv2/gpim_*` |
| accumulate | `*/conv2/acc_*`, `*/conv2/msum_*` |
| M 산출(bisect 포함) | `*/conv2/gbis[*].*`, `*/conv2/siml_*`, `*/conv2/simh_*`, `*/conv2/accH_*`, `*/conv2/gpH_*`, `*/conv2/u_asm/*`, `*/conv2/m_re_flat*`, `*/conv2/m_im_flat*` |

### 3.2 float (pin 안 함) — pblock 에서 **제외**
- `*/conv2/lane[*].u_mul/*` (184 DSP + a_q + per-PE weight RAM/SRL) → DSP 열 고정, 자유 배치.
- row_buffers, collector/tile_out, FSM, weight loader → 자유.

### 3.3 크기·위치 (★ clock region, 실측 anchor)
- core 는 **reduce 가 이미 있는 clock region**(06 기준 X64-65/Y110-131 영역) 을 anchor 로,
  **그 CR + 세로 이웃 1개**(IT 가 들어올 여유) = **약 2 clock region**.
- **좌표 hardcode 금지**: 아래 Tcl 이 live design 에서 reduce anchor 의 CR 을 출력 → 그 값으로 resize.
- 효과: gic[1]/gic[2].u_it(현 X14 왼쪽)가 reduce·tile6_q 옆으로 끌려와 **producer→IT route 단축**,
  D 의 gpab→gpim_q 도 같은 영역 내로 압축. **배치 churn 정지**(class B regression 원인 제거).

## 4. 적용·검증 프로토콜 (반복방지)

1. `wino_floorplan.tcl` **PART 1(진단)** 먼저 source → 각 그룹 현 CR/bbox 출력 확인(설계 가정 검증).
2. PART 2 로 `pb_conv2_core` 생성+cell 할당, 출력된 reduce CR 로 resize.
3. **XDC-only → 기능 bit-exact 자동**(배치만 바뀜). iverilog 불필요.
4. `place_design`(또는 read 후 implement) → `report_timing_summary` → **B(grp_q/tile6_q→tre)·D route 단축** 확인.
5. 판정:
   - WNS ≥ 0 → **200MHz 닫힘**(M bisect + B/D floorplan). 종료.
   - B 잔존(core 가 여전히 산개) → **§5 class B in pblock**(RTL+XDC) 추가.
   - core 과밀(util>~90%, congestion) → CR 1개 더 확장(가로 이웃).

## 5. 잔류 fallback — class B in pblock (그때만 RTL)
floorplan 만으로 B 가 안 닫히면(monolithic tile6_q→4 IT fan-out 이 한계): **tile6_q 를 IT 별 복제**
(`tile6_q_ic`, 옛 class B) **하되 각 복제를 `pb_conv2_core` 안에 고정**. pblock 이 churn 을 막으니
이번엔 standalone class B 같은 regression 안 함(MB_closure §1.3). RTL+XDC, iverilog 100/100 재검.

## 6. 대안(미채택) 기록
- **per-lane pblock ×4**(MB_closure §1.2 원안): IT[k]+lane[k] 를 4 열-슬라이스로 분리.
  → 실측결과 **B 의 병목은 *공유* tile6_q→4IT fan-out** 이라, IT 를 4곳으로 *더 분리*하면 공유 net 이
  오히려 길어질 위험. **core 클러스터(본 §3)가 공유 fan-out 에 더 직접적.** per-lane 은 §5 와 함께라야 유효.
- **IT 입력 register-split(+1 lat)**: route 를 reg 로 끊는 RTL 안(carry-bisect 와 동류, 결정적).
  floorplan 이 안 되면 차선. 사용자 결정 = floorplan 우선.
