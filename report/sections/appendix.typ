#pagebreak()
#heading(numbering: none)[Appendix A. 코드 발췌 (본문에서 참조)]

본문에 인용된 코드 발췌 중 본문에 직접 싣지 않은 것을 모은다(C1·C2·C4·C5는 본문 §3·§5에 있음).

*C3 — `kcol_accumulator.v`: 커널 열 3개를 3사이클에 걸쳐 24-bit 누적 (@sec-conv2-alloc).*
```verilog
always @(posedge clk) begin
    if (rst) begin out <= 24'sd0; out_valid <= 1'b0; end
    else case (phase)            // 0=first, 1=middle, 2=last
        2'd0: out <= in;                 // first : reset + 첫 누적
        2'd1: out <= out + in;           // middle: 누적
        2'd2: begin out <= out + in; out_valid <= 1'b1; end  // last: 누적 + valid
    endcase
end
```

*C6 — `main.c`: 10,000장 inference loop (반대 bank preload + start + done poll) (@sec-quant-hw).*
```c
for (i = 0; i < N_IMG; i++) {
    bank = (i & 1) ? 0x400 : 0x000;          // ping-pong: 반대 bank에 preload
    memcpy(IMEM_BASE + bank, images[i], 784);
    *CTRL = START_BIT;                        // start pulse
    while (!(*STATUS & DONE_BIT)) ;           // done poll
    result[i] = (*STATUS >> 1) & 0xF;         // 4-bit class
}
```

*C7 — `wino_truncate.v`: Winograd 1/16 + layer >>10 을 결합한 `>>>14` + sat + ReLU (@sec-wino-engine).*
```verilog
wire signed [YW-1:0] y_i  = $signed(y16_flat[i*YW +: YW]);
wire signed [SW-1:0] sh_i = y_i >>> SHIFT;    // SHIFT=14 (=4 winograd + 10 layer)
// 이후 saturate(±127) + ReLU → 8-bit 출력 (truncate_relu 와 동일 규칙)
```

*C9 — AXI-Lite write hang 수정: AWVALID && WVALID 동시 조건 (@sec-disc-debug).*
```verilog
// W 가 AW 보다 먼저 와도 안전: 둘 다 valid 일 때만 ready assert
assign awready = ~axi_bvalid & awvalid & wvalid;
assign wready  = ~axi_bvalid & awvalid & wvalid;
```

*C10 — NBA register race 수정: `prior_diff_next` 조합값으로 판정 (@sec-discussion).*
```verilog
// (수정 전) data_ready = (prior_diff < 0)        ← 이전 사이클 stale 값
// (수정 후) 현재 사이클 trigger 를 반영한 조합값 사용
wire signed [2:0] prior_diff_next =
    prior_diff + (rdone ? 3'sd1 : 3'sd0) - (prior_wdone ? 3'sd1 : 3'sd0);
wire data_ready = (prior_diff_next < 3'sd0);
```

#pagebreak()
#heading(numbering: none)[Appendix B. CSR Memory Map & 첨부물]

CSR(AXI-Lite slave, `csr_axi.v`)는 PL 인터페이스로 `enable`/`start`/`img_ready`(PS→PL),
`img_done`/`input_consumed`(PL→PS)와 timer 레지스터를 노출한다. 정확한 주소·비트 필드는
`csr_axi_slave_lite_v1_0_csr.v`와 대조해 확정한다(표 T2).

*첨부 제출물.* 전체 Vivado Block Design은 `archive/v2_overclock_200MHz_backup/`의
`cnn_accel_bd_200MHz.pdf`(블록도)와 `cnn_accel_bd_200MHz.tcl`(재현용 TCL)로 보고서와 함께
제출한다. data-path BMG 파라미터(Port A 32b / Port B 8\~128b)는 `docs/ip_spec/`의 BMG
스펙·스크린샷 참조.

#pagebreak()
#heading(numbering: none)[Appendix C. 팀 협업 & 저장소]

전체 작업은 Git으로 버전 관리했으며, 저장소는 다음 URL에 공개되어 있다.

#align(center)[#link("https://github.com/dohyunKim0309/CNN_Accelerator")[`github.com/dohyunKim0309/CNN_Accelerator`]]

*브랜치 전략.* 팀원별로 독립 브랜치를 두어 각자 맡은 모듈을 병행 개발하고, 모듈이 단위
테스트벤치를 통과하면 통합 브랜치로 병합하는 feature-branch 방식을 따랐다. 팀원 브랜치(`dohyun`,
`dongju`, `jimin`)와 더불어 모듈·기능 단위의 작업 브랜치(예: 두 사람이 공유한 `dohyun_dongju`,
단일 이미지 모듈용 `jimin-single-image-module`)를 분리해 충돌을 줄였다. 약 한 달의 개발 기간
(2026-05-18 \~ 06-19) 동안 *총 201개 커밋, 12개 브랜치, 35회 병합* 이 기록되어, 잦은 통합으로
인터페이스 회귀를 조기에 잡는 협업 흐름을 유지했다.

*역할 분담.* 커밋 분포가 곧 분담을 보여준다.

#figure(
  table(
    columns: 3, align: (left, left, left),
    table.header[팀원][주요 브랜치][담당],
    [김도현], [`dohyun`], [전체 시스템 통합, Complex Winograd 엔진, Conv2, 오버클럭(timing closure), 보고서],
    [김동주], [`dongju`], [Conv1 엔진(`conv1_revised`), MaxPool],
    [신지민], [`jimin`], [FC 엔진(`RTL/fc`), single-image 검증 모듈],
  ),
  caption: [표 T14: 팀원별 역할 분담 (Git 브랜치·커밋 기준)],
)

*제출 관련 기록.* 본 보고서의 대상 RTL·구현·시뮬레이션 검증은 모두 마감 이전에 완료되었으며,
각 작업의 완료 시점은 저장소의 커밋 타임스탬프로 확인할 수 있다.
