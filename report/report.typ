// =============================================================================
// TAS2 Final Report — CNN Accelerator (MNIST, Arty A7-100T)
// Typst source. 컴파일: typst compile report.typ
// 그림 경로: figures/{existing,user,diagrams}/  (부록 D 매니페스트 기준)
// 본문 내용은 TAS2_report_plan.md(§1~§8)에서 옮김.
// =============================================================================

// ---- 문서 설정 -------------------------------------------------------------
#set document(title: "TAS2 Final Report — CNN Accelerator", author: "김도현")
#set page(
  paper: "a4",
  margin: (x: 2.2cm, y: 2.4cm),
  numbering: "1",
  number-align: center,
)
#set text(font: ("Noto Serif CJK KR"), size: 10.5pt, lang: "ko")
#set par(justify: true, leading: 0.72em)
#show heading: set block(above: 1.2em, below: 0.7em)
#set heading(numbering: "1.1")
#show heading.where(level: 1): set text(size: 15pt)
#show heading.where(level: 2): set text(size: 12.5pt)
#show heading.where(level: 3): set text(size: 11pt)

// 코드블록: 본문 코드 발췌용 (sans-serif mono 느낌)
#show raw.where(block: true): it => block(
  fill: luma(245),
  inset: 8pt,
  radius: 3pt,
  width: 100%,
  text(font: ("DejaVu Sans Mono", "Noto Sans CJK KR"), size: 8.5pt, it),
)
#show raw.where(block: false): it => box(
  fill: luma(240), inset: (x: 2pt), outset: (y: 2pt), radius: 2pt,
  text(font: ("DejaVu Sans Mono", "Noto Sans CJK KR"), size: 9pt, it),
)

// ---- 헬퍼: 그림 / 표 / 코드 발췌 -------------------------------------------
// include 는 부모 scope 의 #let 을 공유하지 않으므로 헬퍼는 import 로 노출.
#import "helpers.typ": *

// =============================================================================
// 제목
// =============================================================================
#align(center)[
  #v(3cm)
  #text(size: 22pt, weight: "bold")[CNN Accelerator 설계 보고서]
  #v(0.4cm)
  #text(size: 13pt)[MNIST INT8 추론 가속기 — Arty A7-100T / Vivado / Verilog]
  #v(1.2cm)
  #text(size: 12pt)[
    EEE351 Intelligent System Design and Application \
    Assignment 2 — Final Report (Individual)
  ]
  #v(2cm)
  #text(size: 12pt)[
    전기전자공학과 \
    김도현 (2022142223) \
    8팀
  ]
  #v(1fr)
  #text(size: 10pt, fill: luma(110))[
    TAS2_T\#8_김도현_2022142223.pdf
  ]
]
#pagebreak()

// ---- 목차 ------------------------------------------------------------------
#outline(title: "목차", indent: auto, depth: 2)
#pagebreak()

// =============================================================================
// 0. Abstract
// =============================================================================
#heading(numbering: none, level: 1)[Abstract]

본 프로젝트는 Arty A7-100T FPGA 위에서 MNIST 10,000장을 분류하는 INT8 CNN
추론 가속기를 설계하고, end-to-end latency 최소화를 목표로 최적화하였다.
검증 완료된 INT8 직접 컨볼루션 baseline은 200 MHz로 timing closure(WNS
+0.011 ns)하여 보드에서 *10,000/10,000* 정확도와 약 *98 ms* latency를 실측하였다.
추가로, Conv2의 곱셈을 직접 conv 대비 3.13× 줄이는 *complex Winograd
F(4×4, 3×3)* 와 DSP48E1 한 개로 두 INT8 곱을 처리하는 *SIMD packing* 을 제안·구현하였다.
Winograd 데이터패스는 시뮬레이션에서 bit-exact로 검증되었고 implementation은
171.42 MHz로 timing-met이나, 보드 제출 마감 시점의 시간 제약으로 보드 실측은
수행하지 못해 1만 장 latency를 cycle 추정(~78 ms)으로 보고한다.

// =============================================================================
#include "sections/01_intro_theory.typ"
#include "sections/02_problem_solution.typ"
#include "sections/03_impl_baseline.typ"
#include "sections/04_impl_winograd.typ"
#include "sections/05_optimization_journey.typ"
#include "sections/06_results.typ"
#include "sections/07_discussion.typ"
#include "sections/08_conclusion.typ"
#include "sections/09_references.typ"
#include "sections/appendix.typ"
