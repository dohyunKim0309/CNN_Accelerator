#heading(numbering: none)[References]

#set enum(numbering: "[1]")

+ EEE351 Intelligent System Design and Application, _Assignment: CNN Accelerator_ (과제 명세서).
+ A. Lavin and S. Gray, "Fast Algorithms for Convolutional Neural Networks," _Proc. IEEE CVPR_, pp. 4013–4021, 2016. (Winograd minimal filtering, F(m,r))
+ A. L. Toom, "The Complexity of a Scheme of Functional Elements Realizing the Multiplication of Integers," _Soviet Mathematics Doklady_, vol. 3, pp. 714–716, 1963. (다항식 보간 기반 곱셈; 원본 _Doklady Akad. Nauk SSSR_, 150(3):496–498)
+ S. A. Cook, _On the Minimum Computation Time of Functions_, Ph.D. thesis, Harvard University, 1966. (Toom–Cook 알고리즘 정식화)
+ AMD (Xilinx), _Vivado Design Suite 7 Series FPGA Libraries Guide (UG953)_ — DSP48E1 primitive. #linebreak() #text(size: 9pt)[#link("https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/DSP48E1")] (SIMD weight packing의 DSP48E1 포트·연산 참조)
+ Xilinx, _7 Series DSP48E1 Slice User Guide (UG479)_. (25×18 multiplier 구조)
+ Xilinx, _Convolutional Neural Network with INT4 Optimization on Xilinx Devices (WP521)_. (DSP48E2 INT8/INT4 packing — 본 기법과 대비)
+ M. Véstias et al., "A Configurable Architecture for Running Hybrid Convolutional Neural Networks in Low-Density FPGAs," _Proc. FPL_, 2017. (저밀도 FPGA CNN, INT8 packing 비교 대상)
+ EEE351 Week 9 강의자료 — AXI4-Lite CSR slave 설계 참고.
+ PyTorch — golden reference 모델 및 INT8 양자화 파라미터.

#text(fill: luma(120), size: 9pt)[
  ※ 인용 형식·서지정보는 제출 전 최종 확정한다.
]
