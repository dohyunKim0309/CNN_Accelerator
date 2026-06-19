# Overclock — 가속기 datapath 오버클럭 (두 여정)

Arty A7-100T (`xc7a100t-csg324-1`) INT8 CNN 가속기의 datapath 클럭을 100MHz 에서 올린 기록.
PS/MicroBlaze/AXI/CSR=100MHz, MIG=200(ref)/81.25(ui) 유지하고 **가속기 conv2 datapath 만 `clk_out3`
로 분리 + 경계 CDC**. 두 번의 긴 여정 — direct(baseline) conv2 와 winograd conv2.

| 여정 | 최종 | HW | 핵심 레버 | 진행기록 |
|---|---|---|---|---|
| **direct** conv2 (192 DSP) | **200MHz** ✅ | 10000/10000, **108.9ms**, 1.72× | reset 복제트리 + `max_fanout` (broadcast 벽) | [`direct/journey.md`](direct/journey.md) |
| **winograd** conv2 (184 DSP) | **171.43MHz** ✅ MET | 검증 예정 | **P&R over-constrain** (placer 를 floor 까지 강제) | [`../winograd/winograd_overclock_journey.md`](../winograd/winograd_overclock_journey.md) |

---

## `direct/` — baseline conv2 → 200MHz (HW 확정)
- **`journey.md`** — 100→200MHz 전 여정 (300 목표 → 200 타협, reset fanout 벽 −1.94, ★silent-fail 함정).
- **`design.md`** — 클럭 아키텍처 / CDC / BD / XDC 설계.
- **`timing/`** — 단계별 리포트+스샷 **01~08** (pre-pipeline → 300 시도 → reset-tree → 200 **MET +0.011** → HW 10000/10000).

## `winograd/` — winograd conv2 → 171.43MHz
- **진행기록** = [`docs/winograd/winograd_overclock_journey.md`](../winograd/winograd_overclock_journey.md) (Iter 0~16) — *RTL 설계는 `docs/winograd/` 문서셋과 함께 둠.*
- **`winograd/` 폴더** = route 리포트 **01~12** + impl 레시피 스크립트(`setup_impl_runs.tcl` 등) + `README.md`.
  - `01` synth area → `02~07` RTL 이터레이션 → `08` bisect(churn −0.342) → `09` baseline revert(−0.146)
  - → `10` 171 under-invest(−0.089) → `11` ExtraTimingOpt(−0.045) → **`12` over-constrain MET (+0.222)** ★
- **★결론**: conv2 IT-scatter routing floor **~5.09ns > 5.0ns → 200MHz 불가**. MMCM VCO −1 한계 1200(DS181)
  → clk_out3 천장 = **171.43**(÷7). floorplan 사망(76% LUT 밀도 + reduce-gather intrinsic), bisect revert(churn),
  188 = clk_wiz **silent snap**(요청≠실제). 닫은 레시피 = **over-constrain**(`set_clock_uncertainty` 로 placer 강제).

---

## 두 여정 공통 교훈
1. 이 칩 datapath 벽은 거의 다 **die 전역 high-fanout net 의 route delay**(logic 깊이 아님) → `max_fanout` 복제 / placer 강제.
2. **요청 클럭 ≠ 실제 클럭(clk_wiz snap)** = silent-fail 함정 → impl 후 **`report_clocks` 로 실측** 필수.
3. 측정 전 **timing-clean(positive WNS @ slow corner)** 확인 — 아니면 HW 비교 무의미.
4. **placer 는 제약 만족까지만** 일함(slack 안 모음) → 느슨한 클럭에선 critical 경로를 방치 → over-constrain 으로 강제.
