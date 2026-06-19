# 자산 현황 & 남은 캡처 (갱신: 거의 완료)

## ✅ 확보 완료 (figures/existing — 33장)
- 이론/명세: target_cnn_architecture, maxpool_to_fc_computation, bit_truncation_saturation_for_8bit_quantization
- SIMD packing: dsp48e1_structure, simd_packing_bitmap, weight_no128_check
- Winograd 알고리즘: complex_winograd_f43_transform, winograd_f43_transform, gauss_mul, complex_winograd_intuition
- Direct 구현 리포트: direct_impl_200MHz_timing_summary, direct_impl_200MHz_power_summary, direct_impl_utilization
- Winograd 구현 리포트: winograd_impl_171.42MHz_timing_summary, winograd_impl_171.42MHz_power_summary, winograd_impl_utilization, winograd_171.42MHz_timing
- 클럭: clk_wiz, winograd_clock_settings_1/2/3
- 오버클럭 WNS 단계: 01~04, 150_timing, final_timing, final_power
- 보드 HW: result_04_overclock_200MHz_vitis_overlap_hw
- Winograd TB: winograd_testbench_100image_result

## ✅ 다이어그램 (figures/diagrams)
- F1 = target_cnn_architecture (existing) / F2 = F2_block_design.pdf (archive에서 복사)
- F3 핸드셰이크·핑퐁, F4 데이터 이동, F12 검증흐름 = **에이전트가 SVG 작도 완료**
- F5 Winograd 변환행렬 = complex_winograd_f43_transform / winograd_f43_transform (existing)
- F6 = sobel_pipeline_dataflow.svg

## ⏳ 남은 것 — 이것만 채우면 됨

### 1. 모듈별 테스트벤치 (figures/user/) — **캡처 중**
지금은 placeholder로 처리됨. 캡처되는 대로 아래 파일명으로 넣기:
- [ ] W1_pe_cell_exhaustive.png  (로그)
- [ ] W2_conv1.png  (로그+파형)
- [ ] W3_conv2.png  (로그+파형, K_col 누적)
- [ ] W4_fc.png  (로그+파형)
- [ ] W5_argmax.png  (로그+파형)
- [ ] W6_maxpool.png  (로그만)
- [ ] W7_integration.png  (로그+파형, ping-pong/handshake)

### 2. 본문에 채울 데이터 (사진 아님)
- [ ] References(§9) 실제 문헌
- [ ] 제출 파일명 학번/팀번호 확정

## 📎 제출 시 함께 첨부 (보고서 외 파일)
- archive/v2_overclock_200MHz_backup/ 의 블록 다이어그램 PDF + TCL (F2 원본·제출용)

> 결론: **TB 7장(W1~W7)만 캡처 대기 중**, 나머지 그림·다이어그램은 전부 준비됨.
> 그동안 본문은 있는 자산으로 작성하고 TB는 placeholder로 둠.
