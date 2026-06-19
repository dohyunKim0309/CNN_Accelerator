# vivado_reports — Winograd 200MHz 클로저 Vivado run 기록 (raw)

> 규칙: run 마다 `NN_<단계>_<핵심결과>/` 폴더에 리포트 원본을 넣는다.
> (NN = 시간순. "핵심결과"가 폴더명에 있어야 나중에 뒤지지 않는다.)
> 분석/결정은 `docs/winograd/winograd_overclock_journey.md`(journey Iteration 번호 기준),
> 계획은 루트 `WINOGRAD_200MHZ_CLOSURE_PLAN.md`.

| 폴더 | journey | 내용 | 핵심 수치 |
|---|---|---|---|
| `01_synth_area_lut76` | Iter 6 말 | IT-share(입력변환 8→4) 후 synth utilization | LUT 48,110(75.9%) / FF 62,221 / CS 2,101 — 면적 통과 |
| `02_route_wns-2.04_rb-broadcast` | Iter 7 | 첫 routed (phys_opt 無) | WNS −2.037 / 42,776 EP. worst = rb write broadcast (fo=312, route 93%) → rb LUTRAM 화 |
| `03_route_wns-1.74_output-transform` | Iter 8 | 2차 routed | WNS −1.735 / ~27K EP. 30 worst 중 29 = 출력변환 (logic 10-12단) → IT 3-stage/OT 4-stage |
| `04_route_wns-0.41_wm-equiv-merge` | Iter 10 | 3차 routed (Iter 8+9 일괄 반영) | WNS −0.417 / 7,195 EP. worst 전부 = wm_*_q 4벌이 equiv-merge 로 1벌 병합 (fanout 2,944) → keep |
| `05_route_wns-0.34_endgame-40ep` | Iter 11 | 4차 routed | WNS −0.341 / **40 EP** / TNS −4.6. 4클래스: IT c+d→a_q(−0.34), tile6_q→IT(−0.23), wm lane내(−0.13), gpab→gpre_q(−0.08) |
| `06_route_wns-0.094_MBD-baseline` | Iter 12 | 5차 routed = **★현재 baseline**(revert 후 RTL=이 상태) | WNS −0.094 / **7 EP** / TNS −0.85. 3클래스: **M** `gpim_q→m_im_flat`(logic 58%, carry chain), **B** `tile6_q·grp_q→u_it/tre`(route 68%, fo8~11), **D** `gpab→gpim_q`(net 58%) |
| `07_route_wns-0.150_classB-reverted` | Iter 13 | 6차 routed = **class B(per-IT tile6_q) → regression, revert** | WNS −0.150 / 23 EP / TNS −1.04. IT stage1 `tre` 22 EP(route 68%). class B 가 reduce(M/D) 닫고 IT 악화 → 순손해, revert |

**리포트 생성**: `vivado_reports/wino_report.tcl` 을 `C:/Users/gimdohyeon/` 에 복사 → routed design 에서 `source` →
`wino_ts_146.rpt`(요약)·`wino_paths146.rpt`·`wino_da_146.rpt`·`wino_strata_146.rpt` 4개 생성 (★`146`은 라벨일 뿐, 내용은 현재 design).
→ 새 run 은 `NN_route_wns-<절댓값>_<설명>/` 폴더에 **`wino_strata.rpt` / `wino_paths.rpt` / `wino_da.rpt` / `wino_ts_summary.txt`(ts 는 head -180 요약)** 로 정리.
(`wino_strata.tcl` = strata 단독 구버전, 참고용.)

**floorplan (B·D 벽)**: `vivado_reports/wino_floorplan.tcl` 을 `C:/Users/gimdohyeon/` 에 복사 → placed/routed
design 에서 `source`. PART 1=진단(각 그룹 SLICE bbox+clock region 출력), PART 2=`pb_conv2_core` pblock
생성(주석 처리, CR_RANGE 채우고 해제). 설계·검증 프로토콜 = `docs/winograd/conv2_winograd_floorplan.md`.
