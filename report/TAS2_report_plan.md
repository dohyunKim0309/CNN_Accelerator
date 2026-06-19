# TAS2 Final Report — 작성 계획 & 상세 개요

> CNN Accelerator (MNIST, Arty A7-100T / Vivado / Verilog)
> 산출물: Typst 작성 → PDF 변환. 코드는 전체가 아닌 핵심 발췌만 삽입.
> 제출 파일명: `TAS2_T#팀번호_김도현_학번.pdf` (예: `TAS2_T1_김도현_2026XXXXXX.pdf`)

---

## §0. 작성 전략 (내부 스캐폴딩 — 제출본 제외)

> ⚠ 이 "§0. 작성 전략"은 **작성 가이드용 내부 메모**이며 **최종 제출 PDF에는 포함하지 않는다.** 제출본의 "0. Abstract"(목차상 0번)와는 별개다 — 번호 충돌처럼 보이지만, §0(전략)은 plan 문서 전용, Abstract는 보고서 본문 전용. 최종 PDF는 Abstract부터 시작한다.

### 0.1 줌 레벨로 섹션을 가른다 (핵심 서술 원칙)

이 보고서는 **줌 레벨(zoom level)을 섹션 경계로 삼아** 큰 그림에서 세부로 한 방향으로 내려간다. 한 섹션이 모든 줌을 떠안으면 "큰 그림 → 세부"의 흐름이 깨지므로, 레벨별로 책임을 나눈다.

```
§1 Introduction & Theory   ─ 이론 레벨: 문제 소개 + CNN/MLP/Quant/Winograd '일반 이론'
§2 Problem Definition &     ─ 설계 결정 레벨: "무엇을·왜 택했고 대안을 왜 기각했나"
   Solution                   (시스템 전체 설계 + Complex Winograd F(4×4,3×3) 도입 결정)
§3 Implementation(Baseline) ─ 구현 레벨: §2 결정을 RTL·코드·메모리맵·FSM으로 '어떻게' 실현
§4 Implementation(Winograd) ─ 구현 레벨: Winograd 데이터패스·Conv1 2× 실제 RTL
§5 Optimization Journey     ─ 물리 최적화 레벨: 오버클럭 timing closure 단계별 서사
§6 Results                  ─ 검증·측정 레벨
§7 Discussion               ─ 해석 레벨: 통찰·디버깅·trade-off (사실 아닌 '왜·어떻게 진단')
§8 Conclusion / §9 References
```

각 줌 전이의 예: §2에서 "AXI burst를 받으려 32-bit 비대칭 BRAM으로 설계했다(결정+근거+대안 기각)"라고 *결정*하면, §3에서 "BMG Port A 32b / Port B 8~128b, primitive output register, PS write-only"로 *구현*을 보인다. 같은 사안을 두 번 쓰는 게 아니라 **줌을 한 단계 내리는** 것.

> 배치 원칙(보강): **사실/구조는 Implementation, 통찰/평가·디버깅 서사는 Discussion(§7).** 단 §2는 예외적으로 *설계 결정의 근거·대안 기각*까지 담당(명세의 "justify" 요구 직결). 오버클럭 단계별 서사는 §5에 모았고, "왜·어떻게 진단" 통찰은 §7.

> Baseline(INT8 Direct, 보드 실측 완료: 200MHz 108.9ms→feed-overlap ~98ms, 10000/10000)과 Winograd(Complex F(4×4,3×3), RTL bit-exact 완료·171.42MHz timing met·보드 실측 미수행, 추정 ~78ms)는 §3/§4로 분리. 각 섹션 내부는 다시 **오버클럭 이전(기능 정확성)/이후(timing closure)**로 나눈다.

### 0.2 코드 발췌 원칙

전체 RTL을 붙이지 않고, **설계 결정을 증명하는 최소 발췌(5~15줄)**만 넣는다. 각 발췌는 (1) 어떤 설계 주장을 뒷받침하는지 한 줄 캡션, (2) 파일 경로 각주를 동반한다. 발췌 후보 목록은 부록 A에 정리.

### 0.3 채점자 페르소나 (서술 톤의 기준)

"명세서만 아는 채점자"가 읽고 **아키텍처 / 문제해결 과정 / 새로운 알고리즘 제안**을 완전히 이해하도록 쓴다. 따라서 각 설계 선택마다 *무엇을 했는지*에 더해 **왜 그것을 택했고, 대안 대비 무엇이 나은지**를 반드시 붙인다(명세의 "logical explanation / justify" 요구와 직결).

---

## 보고서 전체 구조 (Top-level 목차)

명세의 5개 필수 블록(Theory / Implementation / Results / Discussion / References)을 모두 포함하되, §0.1의 줌 레벨 원칙으로 재구성한다.

```
0. Abstract (½p)
1. Introduction & Theory          ← 문제 소개 + 일반 이론(CNN/MLP/Quant/Winograd 기초)
2. Problem Definition & Solution  ← 시스템 전체 설계 결정 + Complex Winograd F(4×4,3×3) 도입
3. Implementation — Baseline (INT8 Direct)
4. Implementation — Winograd (제안 알고리즘)
5. Optimization Journey           ← 오버클럭(timing closure) 단계별 서사: 무엇·결과·왜 한 흐름
6. Results
7. Discussion
8. Conclusion
9. References
   Appendix (전체 CSR map, BMG 파라미터 표, 추가 파형)
```

> **§5 Optimization Journey 신설 근거(판단 (b) 확정)**: latency 최적화가 본 프로젝트 최대 차별점인데, 오버클럭 서사를 "무엇(Impl)/결과(Results)/왜(Discussion)"로 흩으면 압권이 드러나지 않는다. **WNS 추적 + 단계별 진단 + directive를 한 섹션에서 시간순**으로 흐르게 해 핵심 기여를 구조로 드러낸다. Implementation(무엇을 만들었나)과 별개의 "물리적 최적화 활동"이라 줌 레벨 원칙과도 정합. Baseline=완결 여정 / Winograd=진행 중, 두 트랙으로 정직하게.

각 섹션 상세 개요는 아래.

---

## 1. Introduction & Theory — 문제 소개 + 일반 이론

> 줌 레벨 = **이론**. 명세가 요구한 CNN / MLP / Quantization 이론과 Winograd minimal filtering의 일반 이론까지를 교과서적 토대로 깐다. "이 프로젝트 고유의 설계 결정"은 §2로 미룬다(이론 ↔ 결정 분리). **아래는 본문 초안.**

### 1.1 서론

본 프로젝트의 목표는 MNIST 손글씨 숫자 10,000장을 분류하는 CNN 추론 가속기를 FPGA(Arty A7-100T) 위에 구현하는 것이다. 평가의 1순위는 10,000장 전체에 대한 **end-to-end latency 최소화**이고, 그 다음으로 전력과 자원 사용량을 고려한다. 명세상 모든 신경망 연산은 PL(Programmable Logic)에서 수행되어야 하며, PS(MicroBlaze)는 메모리 read/write와 start/done 제어, 그리고 타이머 측정만 담당한다.

본 보고서는 세 가지를 명확히 답하는 것을 목표로 한다: (1) 가속기의 전체 아키텍처, (2) 200 MHz timing closure에 이르기까지의 문제해결 과정, (3) 직접 컨볼루션 대비 곱셈을 줄이는 제안 알고리즘(complex Winograd). 본 장에서는 이를 이해하는 데 필요한 일반 이론만 정리하고, 구체적인 설계 결정은 §2 이후에서 다룬다.

### 1.2 CNN 기본 연산과 타겟 네트워크

타겟 네트워크는 두 개의 컨볼루션 레이어, 하나의 max-pooling, 하나의 fully-connected 레이어로 구성된다. 각 컨볼루션은 3×3 커널, stride 1, zero-padding 없음이므로 출력의 높이·너비가 입력보다 2씩 줄어든다. 데이터 흐름은 다음과 같다.

```
Input (1,28,28) → Conv1 (8,1,3,3) → ReLU → (8,26,26)
                → Conv2 (16,8,3,3) → ReLU → (16,24,24)
                → MaxPool 2×2 → (16,12,12)
                → Flatten (W→H→C 순) → 2,304
                → FC (2304→10) → argmax → class(0~9)
```
**[그림 F1: 타겟 CNN 구조도]**

각 연산의 정의는 표준 그대로다. 2D 컨볼루션은 3×3 윈도우와 커널의 MAC(multiply-accumulate), ReLU는 음수를 0으로 클리핑, MaxPool은 2×2 영역의 최댓값, FC는 2,304차원 입력과 (10×2304) 가중치의 행렬-벡터곱이다.

곱셈(MAC) 수를 레이어별로 세면 Conv1 48,672회(6.6%), **Conv2 663,552회(90.2%)**, FC 23,040회(3.1%)이다. 여기서는 이 분포를 사실로만 제시하며, "그러므로 Conv2에 최적화를 집중한다"는 *결정*은 §2.1에서 다룬다.

### 1.3 MLP / Fully-Connected와 분류

마지막 FC 레이어는 MaxPool 출력 (16,12,12)을 width→height→channel 순으로 평탄화한 2,304차원 벡터를, (10×2,304) 가중치 행렬과 곱해 10개 클래스의 logit을 만든다. 그 중 최댓값의 인덱스(argmax)가 예측 숫자다. 이는 단층 퍼셉트론(MLP의 한 층)의 형태이며, 본 가속기는 이 행렬-벡터곱과 argmax를 PL에서 수행한다.

### 1.4 Line-buffer 기반 Sliding-Window 스캔

본 프로젝트의 컨볼루션 엔진이 공통으로 쓰는 입력 스트리밍 원리를 정리한다. 이는 이전 과제의 Sobel edge detection IP에서 검증된 구조를 재사용한 것으로, 여기서는 원리만 설명한다(코드는 싣지 않는다).

BRAM에서 픽셀을 **raster-scan(한 클럭에 한 픽셀)**으로 읽고 이를 line buffer 여러 개에 직렬로 통과시키면, 매 클럭에 **3×3 윈도우 하나**가 완성된다(3×3 커널의 경우 line buffer 2개와 9개의 윈도우 레지스터가 필요하다). 일단 윈도우가 만들어지면 그 안의 9개 탭은 윈도우 레지스터에 모두 동시 가용하다. **[그림 F6: Sobel 파이프라인의 윈도우 shift 데이터 재사용 — `docs/figures/sobel_pipeline_dataflow.svg`]**

이 구조의 중요한 함의는 **한 번에 출력 한 행(OH)씩 진행한다**는 점이다. 따라서 여러 출력 행을 동시에 계산하는 **OH 방향 병렬화**는 line buffer를 갈래내거나 윈도우 레지스터를 복제하고 주소·valid 로직을 다중화해야 하므로 추가 비용이 든다. 이 비대칭은 §2.3에서 OH를 병렬 축으로 쓰지 않은 이유의 근거가 된다. 다만 이 비용은 *윈도우를 만드는* 단계에 대한 것이며, 이미 만들어진 윈도우 *내부*의 커널 축 선택과는 무관하다(그 선택 근거는 §2.3.3).

### 1.5 INT8 Quantization 이론

타겟 네트워크는 signed 8-bit 정수로 양자화되어 학습된 파라미터로 제공된다. 입력 이미지도 원래의 unsigned 8-bit(0~255)에서 signed 8-bit로 전처리된 값으로 주어진다.

추론 중 각 레이어의 누적은 오차를 줄이기 위해 비트를 확장한 정수(본 설계에서는 24-bit)로 수행하고, 출력 직전에 다음 규칙으로 다시 signed 8-bit로 절단한다: **LSB 10비트를 산술 우측 시프트(>>10)한 뒤, 결과가 +127을 넘으면 127로, −128 미만이면 −128로 saturation하고, 하위 8비트를 출력으로 취한다.** 컨볼루션 뒤에는 ReLU가 결합되어 하한이 0이 된다.

여기서 분명히 할 점은, **본 과제는 새로 양자화를 수행하는 것이 아니라 이미 INT8로 양자화된(학습 시 quantization-aware) 파라미터의 추론을 비트-정확하게 재현하는 것**이라는 것이다. 따라서 명세가 요구하는 "양자화 메커니즘의 정확한 기술"은, scale-factor 기반 선형 양자화나 재학습이 아니라 위의 *truncation/saturation 규칙*과 *그것을 하드웨어에서 bit-exact로 재현하는 방식*을 기술하는 것으로 충족된다(하드웨어 구현은 §3.A.4).

### 1.6 Winograd Convolution — 일반 이론

본 절은 표준 Winograd minimal filtering의 일반론만 다룬다. 이 프로젝트가 택한 complex F(4×4, 3×3) 구체 해법과 그 근거는 §2.7에 있다.

Winograd 최소 필터링은 컨볼루션의 곱셈 수를 줄이는 변환 기법이다. 출력 타일 크기 m, 커널 크기 r에 대한 1D 알고리즘 F(m, r)은 직접 계산의 `m·r` 곱셈 대신 `m + r − 1` 곱셈으로 동일한 출력을 낸다. 예컨대 F(2, 3)은 직접 6회(2×3) 대신 **4회**의 곱셈으로 두 출력을 얻는다. 구체적으로 입력 `d=[d0,d1,d2,d3]`, 커널 `g=[g0,g1,g2]`에 대해 네 곱 `m1=(d0−d2)g0`, `m2=(d1+d2)(g0+g1+g2)/2`, `m3=(d2−d1)(g0−g1+g2)/2`, `m4=(d1−d3)g2`를 만들면 출력은 덧셈만으로 `y0=m1+m2+m3`, `y1=m2−m3−m4`가 된다 — 곱셈이 6→4로 줄고 늘어난 비용은 덧셈뿐이다. 2D로 확장한 F(m×m, r×r)은 직접 `m²·r²` 대신 `(m+r−1)²`회의 곱셈을 쓴다.

표준 변환은 다음 형태다.

```
Y = Aᵀ [ (G g Gᵀ) ⊙ (Bᵀ d B) ] A
```

여기서 `g`는 커널, `d`는 입력 타일이며, `G`(weight 변환)·`Bᵀ`(input 변환)·`Aᵀ`(output 변환)는 미리 정해진 상수 행렬이다. 곱셈은 element-wise 곱(⊙)에서만 발생하고, 세 변환은 덧셈·시프트로만 이루어진다 — 즉 변환의 비용을 곱셈기가 아니라 가산기로 치른다.

2D F(4, 3)의 경우 직접 컨볼루션이 출력 타일당 `4²·3² = 144`회인 데 비해 표준 실수 변환은 `(4+3−1)² = 36`회로, 4배의 곱셈 감소를 얻는다. **다만 표준 실수 F(4, 3)의 변환 행렬에는 ±1/24 같은 분수 원소가 들어간다.** 이 분수는 INT8 정수 격자와 어긋나 양자화 시 정밀도 손실을 일으킨다. 이 일반적 난점이 §2.7에서 complex 변환을 도입하는 직접적 동기가 된다.

---

## 2. Problem Definition & Solution — 설계 결정과 근거

> 줌 레벨 = **설계 결정**. 각 항목은 결정·근거·대안 기각을 평서체 흐름으로 엮는다(명세 "logical explanation / justify" 직결). 큰 그림(시스템 전체)에서 시작해 Winograd 도입으로 한 단계 줌인. "Verilog로 어떻게 짰나"는 §3/§4. **아래는 본문 초안.**

### 2.0 문제 정의

본 프로젝트의 목표는 MNIST 10,000장을 Arty A7-100T 위에서 분류하되 **end-to-end latency를 최소화**하는 것이다. 제약은 정확도 무손실(제공된 INT8 파라미터를 비트-정확하게 재현)과 보드 자원 한도(DSP 240, BRAM 135, LUT 63K, FF 126K)다. 평가 우선순위는 latency > power > 자원이며, 모든 설계 선택은 논리적으로 정당화되어야 한다. 이하의 결정들은 이 목표·제약에서 차례로 도출된다.

### 2.1 Conv2를 최적화 1순위로 — MAC의 90.2% 집중

먼저 어디에 노력을 집중할지를 정해야 한다. §1.2의 MAC 분포를 보면 곱셈 연산은 Conv1 48,672회(6.6%), **Conv2 663,552회(90.2%)**, FC 23,040회(3.1%)로, Conv2가 전체의 90% 이상을 차지한다. 따라서 자원 배분과 알고리즘 최적화(후술하는 Winograd)는 모두 Conv2에 집중한다. FC나 Conv1을 먼저 최적화하는 안은 전체 latency 기여가 작아 투자 대비 효과가 낮으므로 택하지 않았다.

### 2.2 DSP48E1 SIMD packing — 1 DSP에 INT8 곱 2개

DSP 분배를 정하기 전에 **연산의 최소 단위**부터 결정해야 한다. 1개의 DSP가 곱셈을 1개 하느냐 2개 하느냐에 따라 분배의 기준 자체가 달라지기 때문이다. 따라서 packing을 분배(§2.3)보다 먼저 다룬다.

Artix-7의 DSP48E1은 25×18 signed multiplier다. INT8 곱을 1개씩만 수행하면 25비트 A 포트가 낭비된다. 대신 두 weight `W0, W1`과 공유 activation `X`를 다음과 같이 한 곱에 싣는다.

```
A = W1·2^17 + W0   (25-bit),   B = X   (18-bit)
A·B = (W1·X)·2^17 + (W0·X)     → 下 17비트 = W0·X,  上 = W1·X
```

DSP48E1의 포트 구성과 packing 비트 레이아웃은 다음 그림과 같다. **[그림 F7: DSP48E1 구조 — A포트(weight 25b)/B포트(activation 18b)/25×18 multiplier/P 48b — `figures/existing/dsp48e1_structure.png`]** **[그림 F8: SIMD packing 비트맵 — packing 없을 때 `[7:0]=W0, [29:8]=sign-extend` vs packing할 때 `[7:0]=W0, [16:8]=guard bits, [24:17]=W1, [29:25]=sign-extend` — `figures/existing/simd_packing_bitmap.png`]** 그림 F8이 보여주듯, W0·X는 하위 17비트(guard bits 포함)에, W1·X는 그 위에 자리하여 둘이 겹치지 않는다.

두 곱이 겹치지 않는 비트 영역에 자리하므로, 한 번의 DSP 연산에서 다음과 같이 분리 추출한다.

```
P0 = W0·X = sint17(P mod 2^17)
P1 = W1·X = sint16(⌊P / 2^17⌋ mod 2^16) + [P0 < 0] - 256·X·ovf
            ( ovf = [W1 = -128 ∧ W0 < 0] )
```

이론상 `W1 = -128 ∧ W0 < 0`에서 25비트 표현이 overflow하므로 산술 보정항 `-256·X·ovf`와 carry 보정 `[P0<0]`을 두어 bit-exact를 보장한다. 다만 **본 과제의 실제 제공 가중치에는 -128이 없다.** Python으로 세 레이어 weight 범위를 전수 확인한 결과 Conv1 [−127, 123], Conv2 [−127, 127], FC [−127, 118]로 **-128 개수가 모두 0**이며, "SIMD packing overflow condition does NOT occur"임을 검증했다. **[그림 F9: weight -128 부재 검증 — 레이어별 min/max·(-128 cnt)·"No Overflow" — `figures/existing/weight_no128_check.png`]** 따라서 이 보정 경로는 본 과제에서 실제로 동작하지 않으며, 그 가치는 실측 성능이 아니라 임의 INT8 가중치에 대한 일반성에 있다(자세한 위치 설정은 §7.1).

여기서 한 가지 결정이 더 따라온다: **무엇을 패킹할 것인가.** Weight에는 -128이 없지만, **Conv1 출력 activation에는 -128이 있을 수 있다.** 만약 activation을 패킹한다면 -128 처리용 추가 로직이 PE마다 필요해 비용이 커진다. 따라서 weight 두 개(`W0, W1`)를 패킹하는 것이 최선이다. 그 귀결로, 한 DSP 묶음에서 나오는 두 결과가 **서로 다른 출력 채널(OC) 두 개**가 되도록 강제된다(OC 방향 packing). 이 사실은 §2.3에서 "왜 IC가 아니라 OC를 2× 방향으로 펼치는지"의 직접 근거가 된다.

이 기법으로 DSP당 throughput이 2배가 된다 — 같은 DSP 예산으로 두 배의 곱셈을 수행한다. 선행연구 대비 차별점은, Xilinx WP486은 DSP48E2(27비트 A 포트) 전용이고 Vestias(FPL'17)는 -128에서 손상이 발생하는 반면, 본 기법은 **DSP48E1(25비트)에서 산술 보정만으로 전 INT8 케이스를 무손상 처리**한다는 점이다(전수 검증은 §6.1).

### 2.3 DSP 분배 논리 — 곱셈 수 비례 분배에서 정수·packing·구조 제약으로

이 절은 §2의 핵심으로, "각 레이어에 DSP를 몇 개 줄 것인가"를 곱셈 수에서 출발해 도출한다. 전개는 다음과 같다: 각 레이어의 연산을 의사코드로 정의하고, 그로부터 곱셈 수를 세고, 곱셈 수에 비례해 240개를 나눈 *이상적*(비정수) 값을 구한 뒤, 정수 제약·약수 제약·packing 방향(§2.2)·구조 단순성을 차례로 적용해 실제 정수 분배로 좁힌다.

#### 2.3.1 각 레이어의 연산 정의 (의사코드)

각 conv 레이어가 어떤 곱셈을 몇 번 하는지를 중첩 루프로 정의한다. 이 루프의 **각 차원(KH, KW, IC, OC, OH, OW)이 곧 병렬화 후보 축**이며, 어떤 축을 병렬화하든 그 병렬도는 해당 차원의 **약수**여야 한다(나누어떨어지지 않으면 잔여 처리 로직이 붙는다). Conv2를 대표로 보이면 다음과 같다.

```
# Conv2: IC=8, OC=16, KH=KW=3, OH=OW=24
for oh in 0..23:
  for ow in 0..23:
    for oc in 0..15:
      acc = 0
      for ic in 0..7:
        for kh in 0..2:
          for kw in 0..2:
            acc += act[ic][oh+kh][ow+kw] * w[oc][ic][kh][kw]
      out[oc][oh][ow] = truncate_relu(acc)   # >>10, saturate(±127), ReLU
```

Conv1(IC=1, OC=8, K=3×3, OH=OW=26)과 FC(2,304→10의 행렬-벡터곱)도 같은 형식의 의사코드로 제시한다. **[의사코드 블록 3개]**

#### 2.3.2 곱셈 수와 이상적 DSP 비례 분배

위 루프로부터 곱셈 수가 정해진다: Conv1 48,672, Conv2 663,552, FC 23,040, 총 735,264회다. 모든 레이어가 같은 시간에 처리를 마쳐 파이프라인이 균형을 이루려면, **곱셈 수에 비례해 DSP를 나누는 것**이 이상적이다(packing의 2배 throughput은 모든 레이어에 공통이므로 비율에는 영향을 주지 않는다). DSP 240개를 모두 쓴다고 가정하면 레이어별 이상적 DSP 값은 다음과 같다.

**[표 T8: 곱셈 수 → 비율 → 이상적 DSP]**

| 레이어 | 곱셈 수 | 비율 | 이상적 DSP (비정수) | 실제 분배 |
|---|---|---|---|---|
| Conv1 | 48,672 | 6.6% | 15.9 | 18 (→ Winograd 단계서 36, §2.8) |
| Conv2 | 663,552 | 90.2% | **216.6** | **192** |
| FC | 23,040 | 3.1% | 7.5 | 16 |

(FC는 약수·병렬화 구조상 16 DSP로 구현되어 이상값 7.5보다 크다. baseline 총합은 192+18+16 = **226/240(94%)**이다.) 문제는 이상값이 정수가 아니라는 점이다. 실제로는 (a) DSP가 정수여야 하고, (b) 병렬도가 각 축의 약수여야 하며, (c) packing이 OC 방향 2×를 강제하고(§2.2), (d) 누적·제어 구조가 단순할수록 좋다. 이 제약들을 Conv2에 적용한 결과가 다음 항이다.

#### 2.3.3 Conv2: 144 기각, 192 확정 (핵심 결정)

먼저 본 보고서에서 사용하는 **축 명명을 RTL(`conv2_engine.v`) 기준으로 고정**한다.

- **언롤(공간 병렬) = K_row(커널 행, KH=3)** — `pe_x[K_row][IC]`로 인덱싱, PE array는 `192 = OC_pair8 × IC8 × K_row3`.
- **시퀀셜 누적 = K_col(커널 열, KW=3)** — `fsm_col_sel`이 한 열씩 선택하고 `kcol_accumulator`가 3사이클에 걸쳐 누적.

즉 **커널 행은 공간적으로 펼치고(병렬), 커널 열은 3사이클에 걸쳐 시분할 누적**한다.

산술부터 명확히 한다. 직접 Conv2의 한 출력 픽셀은 `IC8 × KH3 × KW3 = 72` MAC을 요구하고, 전체는 `72 × OC16 × OH24 × OW24 = 663,552`회로 §2.1과 일치한다. 한 사이클에 처리할 곱셈 수의 두 후보는 다음과 같다.

```
144 = IC8 × K9 × SIMD2          (IC 전체 × 커널 9탭 전부 언롤 × packing 2)
192 = OC_pair8 × IC8 × K_row3   (OC16 packing 2 × IC 전체 × 커널 '행'만 언롤)
```

**144를 기각한 이유**는 §2.3.2의 이상값에 있다. Conv2의 이상적 몫은 216.6 DSP인데, 144만 쓰면 약 70여 개의 DSP가 남는다. 남은 자원만큼 사이클이 길어져 파이프라인 균형이 깨지므로, 한 축의 병렬도를 키워 240 예산에 더 가깝게 채워야 한다.

**확정한 분배는 192 DSP = OC_pair8 × IC8 × K_row3**이다(Conv2 몫). 이는 Conv2의 이상값 216.6에 144보다 훨씬 가까우면서(Conv1 18·FC 16과 합치면 전체 226/240, 94%를 채운다) 동시에 packing이 쉽고 누적 구조가 단순한 방향이다. 세 가지 세부 결정이 여기에 얽혀 있다.

첫째, **왜 OC 방향 2×인가(IC 패킹이 아니라).** §2.2에서 본 대로 한 DSP 묶음의 두 결과는 서로 다른 OC가 되도록 *weight*를 패킹해야 한다. IC를 패킹 축으로 쓰려면 *activation*을 패킹해야 하는데, Conv1 출력 activation에는 -128이 있을 수 있어 PE마다 보정 로직이 붙는다. 따라서 OC를 packing 축으로 택했다.

둘째, **왜 커널 열(K_col)을 펼치지 않고 3사이클 누적하는가.** 한 윈도우의 3×3 = 9탭은 `window_register`에 9개가 모두 동시 가용하므로, 원리상 9탭을 전부 펼치는 것도 가능하다(이는 곧 144 경로다). 그러나 9탭 전부 언롤은 위에서 보았듯 240 예산을 다 쓰지 못하고, 반대로 OC·IC를 더 펼치면 예산을 초과한다. 240 안에서의 균형점이 바로 "커널 행 3개만 공간 언롤 + 커널 열 3개는 3사이클 시퀀셜 누적"이다. 이 경우 누적 경로가 `krow_ic_adder_tree`(행·IC 합) → `kcol_accumulator`(열 3사이클 합)로 단순하게 떨어진다. 이때 한 이미지의 *순수 연산* 사이클은 `OH24 × OW24 × KW3 = 1,728`이고, 여기에 파이프라인 fill/drain 오버헤드가 더해져 실제 throughput floor는 **약 1,799 cyc/img**가 된다(§5.1.0에서 이 값을 latency 추정에 사용).

셋째, **왜 IC나 OC를 더 잘게 쪼개지 않는가.** OC나 IC를 부분 그룹으로 더 나누면 부분합을 따로 보관했다가 나중에 더하거나 time-multiplexing해야 하므로 누적·스케줄 FSM이 복잡해진다. IC=8 전체를 한 번에 펼치면 cross-IC 합이 하나의 가산 트리로 끝나 제어가 간단하다.

대안 옵션(144=9탭 전부 언롤 / IC를 패킹 / OC·IC 추가 분할 / 커널 열도 언롤)과 각 기각 사유를 표로 정리한다. **[표 T9: 병렬화 옵션 vs DSP예산·packing·누적 단순성 → 192 선택]**

> 주: §1.4의 line-buffer 비대칭은 **윈도우를 만드는 단계**(여러 output row를 동시에 생성할 때 line buffer 복제·주소 다중화 비용)에 대한 것이지, 이미 만들어진 윈도우 *내부*의 9탭 선택과는 무관하다. 윈도우 내부 축(K_row/K_col) 선택의 근거는 위의 DSP 예산 트레이드오프이고, §1.4는 OH(출력 행) 병렬화를 쓰지 않은 이유로만 인용한다.

### 2.4 Inter-image pipelining과 분산 FSM 제어

1만 장을 *연속*으로 추론할 때는 단일 이미지 latency보다 stage 간 overlap이 throughput을 좌우한다. 따라서 stage 사이를 ping-pong BRAM 버퍼로 분리하여, 한 engine이 다음 이미지를 쓰는 동안 다음 engine이 이전 이미지를 읽도록 했다. 제어는 중앙 컨트롤러를 두지 않고, 각 engine이 자체 FSM과 bank-toggle FF를 가지며 stage 간 `write_done`/`read_done` 핸드셰이크(각 1-cycle pulse)로만 동기한다.

중앙 컨트롤러(단일 거대 FSM) 방식은 제어 신호가 모든 engine으로 fanout되어 fanout·timing closure에 불리하고, 특히 오버클럭 시 병목이 된다(실제로 §5의 closure에서 high-fanout 제어 net이 반복적으로 문제였다). 분산 제어는 이 부담을 구조적으로 회피한다 — 이 이점의 정량 평가는 §7.5에 둔다.

### 2.5 AXI burst를 위한 32-bit 비대칭 BRAM 설계

PS→PL 데이터 전송은 전체 latency에서 큰 비중을 차지한다(실측에서 CDMA feed가 72%, §7.6). 따라서 data-path BRAM을 **Port A는 32-bit(PS write, AXI burst 친화), Port B는 엔진 소비 폭(8~128-bit)**의 비대칭 구성으로 설계하여, PS 측은 32-bit word·burst로 전송 효율을 높이고 엔진 측은 필요한 폭으로 병렬 read하게 했다.

대안으로 대칭 8-bit 포트는 전송이 비효율적이고, .coe로 BRAM을 초기화하는 방식은 명세가 금지할 뿐 아니라 PS 전송 시간을 측정에서 누락시키므로 모두 기각했다. 모든 weight·image는 PS가 AXI로 write한다.

### 2.6 멀티클럭 사전 설계 (PS 100MHz / PL datapath + CDC)

오버클럭은 PL datapath에서만 의미가 있다. 처음부터 단일 클럭으로 설계하면 클럭을 올릴 때 PS·AXI까지 끌려 올라가 closure가 불가능하다. 따라서 PS(100MHz)와 PL datapath 클럭을 처음부터 분리하고, 경계에 CDC(`cdc_pulse_sync`/`cdc_bit_sync`)를 미리 깔아 두어 후일 PL만 150/200MHz로 올릴 여지를 확보했다. 이 사전 분리가 §5 오버클럭 로드맵 전체의 전제다(구현·동작은 §5.1.1). 단일 클럭 도메인 안은 오버클럭 확장성이 없고 나중에 재설계 비용을 치르게 되므로 택하지 않았다.

### 2.7 Complex Winograd F(4×4, 3×3) 도입

Conv2가 곱셈의 90%를 차지하므로(§2.1), 곱셈 수 자체를 줄이는 알고리즘적 접근이 가장 효과적이다. 여기에 **complex Winograd F(4×4, 3×3)**를 도입했다. 보간점으로 {0, ∞}와 1의 4제곱근(±1, ±i)을 택하면 변환행렬 G·Bᵀ·Aᵀ가 모두 Gaussian integer가 되어 분수가 전혀 없다. **[행렬 G / Bᵀ / Aᵀ]**

실수 입력에 대해 켤레 대칭 `s(-i) = conj(s(i))`가 성립하므로 복소 보간점의 절반은 추가 계산 없이 얻어지고, 복소 곱 1회는 Gauss 트릭(`k1=a(c+d), k2=c(b-a), k3=d(a+b)`)으로 실수 곱 3회로 줄어든다. 그 결과 한 타일당 곱셈은 (real,real) 16 + (real,cplx) 4×3 + (cplx,real) 4×3 + (cplx,cplx) 2×3 = **46회**가 된다. (이 16/4/4/2 분해가 *어느* 보간점 쌍에서 나오는지는 위 G·Bᵀ·Aᵀ 행렬의 실수/복소 위치에서 직접 읽힌다 — **[그림 F5: 6×6 타일의 보간점 격자와 실수·복소·켤레 위치 표시]**로 시각화하여 독자가 분해를 따라올 수 있게 한다.) 전체로 환산하면 직접 conv의 663,552회가 211,968회로, **3.13× 감소**한다. 1/16 스케일은 출력 `>>14` 시프트에 흡수되어 직접 conv와 비트-정확하게 일치한다.

여기서 핵심 결정은 **실수 F(4,3)(36회, 4×)이 아니라 complex(46회, 3.13×)를 택한 것**이다. 실수 변환은 곱셈이 더 적지만 변환행렬에 ±1/24 같은 분수가 있어 INT8 격자와 어긋나 정밀도 손실을 일으킨다(§1.6). 본 과제는 정확도 무손실이 제약이므로, 4×의 일부를 bit-exact 보장과 맞바꾼 complex 변환이 정당하다.

### 2.8 Conv1 2× rebalance

Conv2를 Winograd로 빠르게 만들면 병목이 Conv1로 이동한다. 따라서 Conv1을 DSP 18→36으로 늘리고 2-round를 1-round로 바꿔 약 837 cyc로 재균형했다. Conv1을 방치하면 Winograd의 3.13× 이득이 Conv1에 가려져 무의미해지므로, rebalance는 선택이 아니라 필수다. "지엽적 최적화가 전역 병목을 바꾼다"는 이 병목 이동의 정량 분석(표 T3)은 §7.5에 모아 서술하고, 여기서는 결정 사실만 둔다.

---

## 3. Implementation — Baseline (INT8 Direct)

> 줌 레벨 = **구현**. §2에서 내린 설계 결정을 RTL·코드·메모리맵·FSM으로 *어떻게 실현했는지*. "왜 이 구조인가"는 반복하지 않고 §2 해당 항목을 가리킨다. **아래는 본문 초안.** 구성: §3.0 공통 골격 → §3.A 레이어 엔진 → §3.B(오버클럭은 §5로 위임).

### 3.0 공통 시스템 골격 — 분산 데이터플로우 제어의 구현

Baseline과 Winograd가 공유하는 골격을 여기서 한 번만 구현 차원으로 서술한다. 설계 결정과 근거는 §2.4~2.6에 있다.

#### 3.0.1 PS-PL 블록 구성

전체 시스템은 Vivado Block Design 상에서 MicroBlaze(PS), AXI Interconnect, AXI BRAM Controller ×4, CSR(AXI-Lite slave), 그리고 가속기 본체 `cnn_accelerator`(PL)로 구성된다. **[그림 F2: 블록 다이어그램]** 명세 제약대로 모든 신경망 연산은 PL에서 수행되고, PS는 메모리 read/write와 start/done 제어, 타이머 측정만 담당한다. .coe로 BRAM을 초기화하는 것이 금지되므로 모든 weight·image는 PS가 C 헤더 배열에서 AXI를 통해 BRAM으로 전송한다.

멀티클럭은 §2.6의 결정대로 구현했다. PS·AXI·CSR는 100 MHz(aclk), datapath는 별도 클럭(clk)으로 분리하고, 두 도메인의 경계 신호는 CDC 동기화기로 건넌다(구현·동작 상세는 §5.1.1). **[코드 발췌 C4: CDC]**

#### 3.0.2 데이터플로우 구현

데이터플로우는 **Weight Stationary + Output Stationary, Activation Flowing**으로 실현된다. 각 PE는 weight를 자기 레지스터에 적재해 추론 동안 고정하고(weight stationary), 부분합(psum)을 누적기에 모으며(output stationary), activation만 BRAM → line buffer → window register → PE로 매 사이클 흐른다(activation flowing).

#### 3.0.3 Inter-image pipelining과 분산 FSM 구현

§2.4의 결정대로, stage 사이를 ping-pong BRAM 버퍼로 분리하여 한 engine이 다음 이미지를 쓰는 동안 다음 engine이 이전 이미지를 읽는다. 중앙 컨트롤러는 없으며, 각 engine이 자체 FSM과 bank-toggle FF를 가지고 stage 간 `write_done`/`read_done`(각 1-cycle pulse) 핸드셰이크로만 동기한다. **[그림 F3: 핸드셰이크/핑퐁 + FSM 흐름]** 각 FSM의 상태 전이는 레이어마다 다르므로, 구체 상태는 아래 엔진별 소섹션(§3.A.1)에서 제시한다.

### 3.A 오버클럭 이전 — Baseline 레이어 엔진 (정확성 확보)

#### 3.A.1 레이어별 엔진 RTL

**PE cell (`pe_cell.v`).** 모든 컨볼루션·FC가 공유하는 MAC 단위다. DSP48E1 한 개와 parameterized weight 레지스터로 구성되며, A 포트(25-bit)에 packed weight, B 포트(18-bit)에 activation을 싣고 48-bit P에서 두 곱 `mul0=W0·X`, `mul1=W1·X`를 분리 추출한다(§2.2). 파라미터 `DEPTH`로 weight 슬롯 수를 정해 레이어별로 재사용한다 — Conv1은 DEPTH=2(OC round mux), Conv2는 DEPTH=3(K_col time-mux), FC는 STREAM=1(weight 레지스터 우회). DSP 3단 + 출력 레지스터 1단 = 4-cycle latency. **[코드 발췌 C1: P0/P1 추출 + carry 보정]** `RTL/core/pe_cell.v`

**Conv1 (`conv1_engine`/`conv1_fsm`).** 입력 (1,28,28) → 출력 (8,26,26). 18 DSP(K=9 unroll × OC_pair=2 × SIMD=2)를 쓰며, 출력 8채널을 2-round(OC0–3, OC4–7)로 나눠 처리한다. line buffer와 window register로 3×3 윈도우를 스트리밍 생성한다. FSM은 IDLE→LOAD→RUN1→FLUSH1→LBRST→RUN2→FLUSH2→DONE의 8상태다. `RTL/conv1/`

**Conv2 (`conv2_engine`/`conv2_fsm`).** 입력 (8,26,26) → 출력 (16,24,24). §2.3의 분배대로 **192 DSP = OC_pair8 × IC8 × K_row3**를 쓴다. 누적 경로는 `krow_ic_adder_tree`(커널 행 3 × IC 8 = 24입력을 22-bit로 합치는 5단 트리)와 `kcol_accumulator`(커널 열 3개를 3사이클에 걸쳐 24-bit로 누적)로 구성된다. 8개 IC를 병렬 처리한다. **[코드 발췌 C3: kcol_accumulator]** `RTL/conv2/`

**MaxPool (`maxpool_engine`).** 2×2 최댓값 풀링. `max_compare_tree`가 16채널 각각에 대해 4-way 최댓값을 조합 논리로 계산한다. `RTL/maxpool/`

**FC (`fc_engine`).** 2,304 → 10. weight를 분산 BRAM에서 병렬 streaming read하며(레지스터 적재 없이 PE에 직결), `fc_accumulator`가 10개 클래스 logit을 24-bit로 누적한다. 마지막으로 `fc_argmax`가 최댓값 인덱스를 찾는다 — 1-cycle combinational 10-way 비교는 타이밍 위반이므로 10→5→3→2→1의 4-round 토너먼트로 분해해 각 round를 레지스터로 끊었고, strict '>' 비교로 동률 시 낮은 인덱스를 유지한다(4-cycle latency). `RTL/fc/`

**Truncate/ReLU (`truncate_relu.v`).** 모든 레이어 출력 직후의 양자화 단이다. 24-bit signed 누적값을 `>>>10`(산술 우측 시프트)한 뒤 [−128, 127]로 saturation하고 ReLU를 적용해 8-bit로 출력한다. 음수 분기에서 ReLU와 음수 saturation이 함께 처리된다. 동시 출력 채널 수 N은 Conv1에서 4, Conv2에서 16이다. **[코드 발췌 C2: >>>10 + sat + ReLU]** `RTL/core/truncate_relu.v`

#### 3.A.2 메모리 구조와 데이터 이동

stage 간 ping-pong 버퍼는 Input / C1C2 / C2Pool / PoolFC 네 곳에 각 2 bank으로 둔다. 각 버퍼의 크기·BRAM 수·핸드셰이크 신호를 표로 정리한다. **[표 T1: 핑퐁 버퍼]**

weight BRAM은 레이어별로 독립적이다. Conv1·Conv2 weight는 적재 후 PE 레지스터에 stationary하게 고정되고, FC weight(약 23 KB)는 streaming read를 위해 여러 BRAM에 분산 배치된다. 각각 독립된 AXI BRAM Controller에 매핑되어 PS가 병렬로 적재할 수 있다.

§2.5의 결정대로 data-path BRAM은 비대칭 포트로 구성된다 — Port A는 32-bit(PS write, AXI burst), Port B는 엔진 소비 폭(8~128-bit)이다. 구체적인 BMG 파라미터는 부록에 둔다.

이미지 한 장의 데이터 이동 경로는 다음과 같다: PS → Input BRAM → Conv1 → C1C2 → Conv2 → C2Pool → MaxPool → PoolFC → FC → Output BRAM → PS. **[그림 F4: 단일 이미지 데이터 이동]**

#### 3.A.3 PS-PL 인터페이스 (CSR와 main.c)

CSR는 AXI-Lite slave(`csr_axi.v`)로, PL과의 인터페이스 신호로 `enable`/`start`/`img_ready`(PS→PL)와 `img_done`/`input_consumed`(PL→PS)를 노출한다. 레지스터 주소 맵과 타이머 레지스터의 구체 비트 필드는 표로 정리한다. **[표 T2: CSR map]** *주의: 실제 주소·비트 필드는 `csr_axi_slave_lite_v1_0_csr.v`와 대조해 작성.* 타이머는 명세 정의대로 "첫 weight write부터 마지막 output read까지"를 PL에서 카운트하여 PS가 읽을 수 있게 노출한다.

PS 측 펌웨어(`main.c`)의 흐름은 다음과 같다: weight를 한 번 전송한 뒤 타이머를 시작하고, 10,000장 루프에서 다음 이미지를 반대 bank에 preload하면서 start를 주고 done을 polling하여 결과를 읽는다. 마지막 이미지의 결과를 읽으면 타이머를 멈춰 총 latency를 보고한다. **[코드 발췌 C6: inference loop]** `vitis/main.c` 데이터는 .npy를 C 헤더로 변환해 빌드 시 DRAM에 올리며, 명세 권고대로 UART 전송은 쓰지 않아 통신 지연을 측정에서 배제한다.

#### 3.A.4 양자화 메커니즘의 HW 구현

설계 결정·근거는 §2.2(SIMD packing)에 있고, 여기서는 양자화 메커니즘을 하드웨어에서 어떻게 bit-exact로 구현했는지에 집중한다(명세가 콕 집은 항목 — PE 구조, accumulator, truncation/rounding, 메모리 대역폭 — 에 대응).

양자화는 §1.5의 명세 규칙(>>10 → saturate(±127) → ReLU)을 24-bit 누적 → 산술 시프트 → saturation 경로로 비트-정확하게 재현한 것이다(`truncate_relu`, C2). 이는 단순 비트-절단이 아니라 명세 규칙의 정확한 모사이며, 본 과제는 이미 INT8로 양자화된 파라미터의 추론을 정확히 재현하는 문제이지 scale-factor 선형 양자화나 재학습이 아니다(§1.5).

INT8 정밀도에 맞춘 하드웨어 적응은 다음과 같다: SIMD-2 packing PE 구조(§2.2), 24-bit accumulator, truncate/round 로직(`truncate_relu`), 그리고 비대칭 BRAM 포트·대역폭(§2.5). Output/Weight Stationary와 채널별 line buffer 선택의 근거는 §2.4에 있다.

### 3.B 오버클럭 이후 — 안내 (상세는 §5 Optimization Journey)

Baseline의 200 MHz timing closure에 적용한 RTL·제약·구조 변경은 무엇·결과(WNS)·왜를 한 흐름으로 다루기 위해 §5 Optimization Journey에 모았다. 본 §3은 오버클럭 이전의 기능 RTL에 집중한다. 다만 한 가지는 여기서 못박는다: **오버클럭 관련 모든 변경은 기능을 바꾸지 않으며(시뮬레이션 bit-exact 재검증), "오버클럭 이전/이후"는 정확성과 무관하다.** 단계별 전개는 §5.1.

---

## 4. Implementation — Winograd (제안 알고리즘)

> 줌 레벨 = **구현**. §2.7(Complex Winograd 도입 결정)·§2.8(Conv1 2×)을 RTL로 실현. 추가 크레딧 대상("전용 아키텍처"). RTL은 시뮬레이션 bit-exact로 검증 완료, implementation은 171.42 MHz로 timing-met(200 MHz는 미달), 보드 실측은 시간상 미수행임을 정직하게 위치시킨다. *왜 Winograd·왜 complex인가*는 §2.7이므로 반복하지 않는다. **아래는 본문 초안.**

### 4.A 오버클럭 이전 — Complex F(4×4,3×3) 데이터패스 구현 (정확성 확보)

#### 4.A.1 Winograd 엔진 RTL 구조

Conv2 Winograd 엔진(`conv2_winograd_engine.v`)은 입력 (8,26,26) INT8을 6×6 타일 단위로 받아 (16,24,24) INT8을 내는, 직접 conv2와 동일한 외부 인터페이스의 drop-in 모듈이다. 내부는 네 단계의 데이터패스로 구성된다.

**입력 변환 (`wino_input_transform`).** `V = Bᵀ·d·B`를 계산한다. 변환 계수가 {0, ±1, ±4}뿐이라 **곱셈기를 전혀 쓰지 않고** 시프트·덧셈으로만 수행한다. 6×6 타일의 8-bit 입력 원소를 변환해 곱셈에 들어갈 14-bit operand들로 펼치며(이 operand들이 §2.7의 46개 곱과 1:1 대응), 3-stage 파이프라인이다. (여기서의 "operand 수"는 §2.7의 곱셈 수와 같은 값이지 타일 크기 6×6=36과 혼동하지 말 것 — 곱셈 감소 비교는 §2.7의 144→46이다.)

**곱셈 배열 (`wino_mul_array` / `wino_dsp_mul`).** element-wise 곱을 수행하는 곱셈기 군집으로, **4개 lane(각 IC 그룹) × 46 곱 = 184 DSP**를 쓴다. 각 DSP48E1은 12-bit weight × 14-bit activation → 24-bit 곱의 3-stage 구성이다. weight는 per-PE distributed LUTRAM에 저장한다(`wino_weight_loader`가 PS write를 받아 적재). `wino_lane_reduce`가 46개 곱을 Gauss 트릭에 따라 26개 부분합으로 축약하고, `wino_m_assemble`이 켤레 대칭으로 36개 M 위치로 확장한다.

**출력 변환 (`wino_output_transform`).** `Y = Aᵀ·M·A`를 계산한다. 계수가 {0, ±1}뿐이라 역시 곱셈기 없이 덧셈으로만 수행하며, 4-stage 파이프라인으로 28-bit 출력을 낸다.

**절단 (`wino_truncate`).** Winograd 변환의 1/16 스케일과 레이어 양자화 >>10을 결합한 `>>>14` 시프트 + saturation + ReLU로 직접 conv2와 동일한 INT8 양자화를 재현한다. **[코드 발췌 C7: `>>>14` 결합]**

엔진 latency는 issue로부터 M_valid까지 +11~12 cycle, tile_out까지 +17 cycle이다. 한 이미지 처리 사이클은 top-module TB 측정 기준 **평균 약 1,341 cyc/img**(100장 합계 132,759 cyc)이다. `RTL/conv2_winograd/`

#### 4.A.2 Conv1 2× rebalance 구현

§2.8 결정대로 Conv1을 DSP 18→36, 2-round→1-round 구조로 바꿨다. PE 군집을 2그룹×9에서 4그룹×9(36 DSP)로 늘려 사이클당 출력을 4 OC에서 8 OC로 두 배로 하고, RUN2·FLUSH2·LBRST 상태를 제거해 FSM을 8상태에서 5상태(IDLE/LOAD/RUN/FLUSH/DONE)로 단순화했다. 이로써 한 이미지가 1,634 cyc에서 **837 cyc**로 줄었다(−797 cyc). 데이터패스 깊이와 FLUSH 길이는 불변이다. `RTL/conv1_2x/`

여기서는 구현만 다룬다. 결정·근거는 §2.8, 병목 이동 정량 분석(표 T3)은 §7.5에 있다.

#### 4.A.3 SIMD packing의 Winograd 적용

§2.2의 SIMD packing을 Winograd 곱셈 배열에도 적용한다. 전체 DSP 사용량은 Winograd Conv2(184) + Conv1 2×(36) + FC(16) = 합성 결과 **236/240(98.33%)**로 거의 포화 상태다(§6.4 hierarchical util). weight에 -128이 없으므로 packing이 무손상이고, Winograd 누적에서도 bit-exact가 보장된다(보정의 일반성 측면 가치는 §7.1).

### 4.B 오버클럭 이후 — 안내 (상세는 §5 Optimization Journey)

Winograd의 timing closure(200 MHz 시도 → 171.42 MHz met)는 §5.2 Optimization Journey — Winograd 트랙에서 다룬다. 본 §4는 오버클럭 이전의 bit-exact RTL에 집중한다.

---

## 5. Optimization Journey — Timing Closure 서사

> 줌 레벨 = **물리 최적화 활동**. Implementation(무엇을 만들었나)과 별개로, "기능 완성된 설계를 어떻게 200MHz로 닫았나"를 **무엇·결과(WNS)·왜를 한 흐름**으로. 두 트랙: §5.1 Baseline(완결) / §5.2 Winograd(진행 중). 각 단계는 사용한 진단 명령(report_timing/report_high_fanout_nets/report_clocks 등)·찾아낸 병목·적용 directive·WNS 변화를 시간순으로.
>
> 핵심 정합성: 모든 변경은 **기능을 바꾸지 않는다**(시뮬레이션 bit-exact 재검증). "오버클럭 이전/이후"는 정확성과 무관하며, 측정 신뢰성은 §5.3(silent timing failure 교훈)로 담보.

> **[작성 메모]** 아래 §5.1은 **본문 초안(평서체)**이다. 단계별 진단 명령·출력 로그·WNS·캡처를 시간 순서대로 싣는다. 캡처는 `docs/timing/`에 실재하는 것만 인용(없는 단계는 사진 생략). 모든 RTL/제약 변경은 시뮬레이션 bit-exact 재검증으로 기능 불변을 확인했다.

### 5.1 Baseline Track — 100 → 200MHz (완결, MET +0.011 ns)

본 절은 timing closure 과정을 **시간 순서대로** 기술한다. 각 단계에서 사용한 진단 명령, 그때 드러난 병목, 적용한 조치, 그리고 그 결과의 WNS(Worst Negative Slack)를 함께 싣는다. 관통하는 주제는 하나다: **이 설계의 타이밍 벽은 거의 전부 die 전역으로 퍼지는 high-fanout 제어·리셋 net의 route delay였으며, 로직 깊이 문제가 아니었다.** (워스트 경로의 route 비중이 82~86%였다는 사실이 그 근거다.)

#### 5.1.0 왜 오버클럭인가 — compute-bound 판별
가속기의 throughput floor는 conv2 사이클(약 1,799 cyc/img)이 지배한다. 같은 cycle 거동을 더 빠른 클럭에서 돌리면 firmware를 바꾸지 않고도 wall-clock latency가 줄어든다(타이머가 세는 100 MHz cycle 수 자체가 감소).

다만 여기서 한 가지를 먼저 확인해야 한다: **현재 latency가 정말 연산(compute)에 묶여 있는가, 아니면 데이터 전송(PS→PL feed)에 묶여 있는가.** 이는 *예상 연산 시간*과 *실측 시간*을 비교하면 판별된다.

```
예상 연산 시간 ≈ (conv2 병목 cyc/img) × (이미지 수) × (클럭 주기)
             = 1,799 × 10,000 × (1/200MHz) ≈ 90 ms   (compute-only 하한)
실측(200MHz, feed-overlap 후) = 98 ms
```

실측이 compute-only 하한에 근접하면 설계는 **compute-bound**이고, 클럭 상승이 직접 latency로 환원된다. 반대로 실측이 크게 벌어지면 여전히 **데이터 전송(feed) bound**이다. 본 설계에서 두 값의 비교 및 그 함의(병목이 어디에 있는가)는 §6.2·§7.6에서 수치로 다룬다.

> 주: 목표 클럭은 처음 300 MHz였으나, closure를 진행하며 die 전역 잔여 위반이 비현실적으로 커 **중간에 목표 자체를 200 MHz로 낮췄다**(이 결정의 맥락은 §5.1.5).

#### 5.1.1 선행 인프라 — dual-clock CDC (PS/AXI ↔ datapath 분리)
가속기만 빠른 클럭으로 돌리려면 PS·AXI·CSR(100 MHz)와 datapath(빠른 클럭) 사이에 **clock-domain crossing(CDC)**이 필요하다. 두 클럭은 동일 MMCM(Clocking Wizard) 출력이라 위상이 정렬되어 있어 그 자체로 비교적 안전하지만, **metastability를 추가로 줄이기 위해** 경계마다 동기화기를 둔다. 신호의 성질에 따라 두 모듈로 분리하였다 — **level 신호는 2-FF 동기화기**, **1-cycle pulse 신호는 toggle 기반 동기화기**(빠른 클럭에서 펄스가 여러 cycle로 보여 "N배 카운트"되는 것을 방지).

CDC가 실제로 사용되는 곳은 `cnn_accelerator` 모듈과 외부의 경계 **총 5곳**이다.

| 신호 | 방향 | 종류 | 동기화기 |
|---|---|---|---|
| `start` | aclk(100) → clk(datapath) | pulse | `cdc_pulse_sync` |
| `img_ready` | aclk(100) → clk | pulse | `cdc_pulse_sync` |
| `img_done` | clk → aclk(100) | pulse | `cdc_pulse_sync` |
| `input_consumed` | clk → aclk(100) | pulse | `cdc_pulse_sync` |
| `enable` | aclk(100) → clk | level | `cdc_bit_sync` |

즉 **펄스 4곳 + 레벨 1곳**이다. 핵심 코드는 다음과 같다.

```verilog
// (1) level 동기화기 — 2-FF (cdc_bit_sync.v): enable 신호용
(* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;
always @(posedge dst_clk)
    if (dst_rst) sync <= 0;
    else         sync <= {sync[STAGES-2:0], d_in};
assign d_out = sync[STAGES-1];
```

```verilog
// (2) pulse 동기화기 — toggle 인코딩 + edge 복원 (cdc_pulse_sync.v)
always @(posedge src_clk)               // src: pulse 마다 toggle 반전 (event=edge)
    if (src_rst)       tgl <= 1'b0;
    else if (pulse_in) tgl <= ~tgl;
(* ASYNC_REG="TRUE" *) reg sync0, sync1; reg sync2;
always @(posedge dst_clk) begin          // dst: 2-FF 동기 + 1 지연
    sync0 <= tgl; sync1 <= sync0; sync2 <= sync1;
end
assign pulse_out = sync1 ^ sync2;        // toggle edge = dst 1-cycle pulse
```

Clocking Wizard 설정과 위상 정렬은 다음 캡처와 같다.

- **[그림 P1: Clocking Wizard 블록 (`docs/clk_wiz.png`)]**
- **[그림 P2: Clocking Wizard 내부 — datapath clk_out phase 정렬 체크 (캡처 예정, 플레이스홀더)]**

#### 5.1.2 MMCM 제약 — "188 MHz는 존재하지 않는다"
Clocking Wizard(MMCM)는 `clk_out1=100`(PS/AXI)과 MIG IDELAYCTRL용 200 MHz가 **VCO 주파수를 고정**한다. 따라서 datapath용 `clk_out3`는 그 VCO의 **정수 분주**만 가능하여, 실제로 생성 가능한 값은 **{200, 171.4, 166.7, 150, …}의 이산 집합**이다.

다만 여기서 함정이 발생한다: **188 MHz를 요청해도 Clocking Wizard가 200 MHz로 스냅한다.** 따라서 "190/188로 타협"은 실제로는 불가능했고, 닫을 수 있는 후보는 낮은 쪽(171.4 / 166.7 / 150)이거나 높은 쪽(200, 닫힌다면)뿐이었다. 이 스냅은 뒤의 silent timing failure(§5.1.5)의 결정적 빌미가 된다. 따라서 클럭 목표를 정하기 전 `report_clocks`로 **실제 period가 요청값과 같은지** 먼저 확인해야 한다.

#### 5.1.3 출발점 — 데이터패스 BRAM에 primitive output register 추가
closure의 첫 조치로, 모든 data-path BRAM(Input / C1C2 / C2Pool / PoolFC)의 출력에 **primitive output register**를 켰다. 이는 BRAM→로직으로 이어지는 조합 경로를 레지스터로 끊어, BRAM read 직후 단을 파이프라인 경계로 만든다. 이로써 이후 단계가 순수 datapath 로직 타이밍에 집중할 수 있게 된다.

- **[IP 스펙: BMG output register 설정 캡처 — `docs/ip_spec/` 참조]**

#### 5.1.4 초기 −8.6 ns → 100→150 MHz (조합 깊이 + conv2 broadcast)
초기 합성의 WNS는 **−8.6 ns**였다(**[그림: `docs/timing/01_pre-pipeline_wns-8.6.png`]**). 진단 결과 주범은 두 가지 조합 깊이 병목이었다: FC argmax의 17-input 9-level 비교 트리와 conv1의 9-input combiner. 이를 argmax는 **4-round tournament**로(C8), conv1 adder는 1→4 stage로 파이프라인화하였다.

그 다음, 300 MHz를 목표로 한 합성에서 WNS **−2.99 ns**, failing endpoint 110,302개가 나왔으며 **전부 datapath intra-clock(`clk_out3→clk_out3`)**이었다(**[그림: `docs/timing/02_300mhz_conv2-broadcast_wns-2.99.png`]**, 로그 `02_..._wns-2.99.txt`). 진단 명령은 다음과 같다.

```tcl
report_timing_summary                              ; # 요약 + 워스트 1개
report_timing -setup -max_paths 44 -file paths.rpt ; # 위반 전체 덤프 (콘솔 붙여넣기보다 -file 이 안정적)
report_high_fanout_nets -timing                    ; # high-fanout net 식별
```

워스트 경로를 보면 **route 86% / logic 14%** — 즉 로직 깊이가 아니라 배선 거리 문제였다. 원인은 conv2의 제어·weight broadcast(`state`/`sel`/`pe_en`/`packed_w`)가 **192개 PE로 fanout**되는데, DSP를 226/240(94%)까지 쓰다 보니 PE가 die 전역 DSP 컬럼에 깔려 broadcast가 본질적으로 die-spanning이 된다는 점이다. DSP 위치는 고정이라 floorplan이 불가능하므로, 레버는 **파이프라인 + 드라이버 복제**뿐이다. 적용한 조치는 누적적으로 다음과 같다.

1. `max_fanout=32` (conv2_fsm `state`/`kw_cnt`, weight_loader `pe_id` 등) + `phys_opt -directive AggressiveFanoutOpt` → −2.99 → **−2.454**.
2. weight broadcast에 +1 register(1회성 weight-load라 compute 무영향) → 진행.
3. `PE_BC_DELAY` 파라미터로 PE 입력단(`sel`/`pe_en`/`pe_x`)에 register를 복제, broadcast가 PE 클러스터 근처 replica에서 출발하도록 단축 → **−2.187**(**[그림: `docs/timing/03_300mhz_step1b-step2_wns-2.187.png`]**, 로그 `03_..._wns-2.454`/`03_...isolation.txt`).
4. weight_loader의 주소·pe_id 계산을 6-level 중첩 곱셈에서 단조증가 accumulator로 대체(조합 깊이 6→1).

300 MHz는 broadcast를 닫아도 reset·FSM 잔여 위반(−1.7~−1.94)이 die 전역에 남아 비현실적이었다. **따라서 목표를 낮춰 150 MHz에서 깨끗이 닫았고, 150 MHz 합성 빌드로 MNIST 10,000장을 보드에서 10000/10000 분류함을 확정**하였다(**[그림: `docs/timing/150_timing.png`]**).

#### 5.1.5 150→200 MHz — silent timing failure 진단, 그리고 reset fanout
**문제 발생.** 150 이후 "200 MHz 빌드인데 wall-clock이 100 MHz와 동일(18.77 M cyc)"이라는 측정이 나왔다. 처음에는 이를 "오버클럭을 더 해도 latency가 안 줄어든다 = 전송(feed) bound"로 해석할 뻔했다.

**원인 파악.** 그러나 그 "200 MHz 빌드"는 사실 **silently fail한 빌드**였다. §5.1.2의 스냅 때문이다: 188 MHz로 설정 → Clocking Wizard가 200 MHz로 스냅 → 실제로는 200 MHz로 돌면서 reset 경로(−1.94 ns)가 위반 → 분산 FSM·in-flight 카운터 구조가 desync되어 중간에 멈춤/오작동. Vivado는 *요청 클럭(188)* 기준으로 통과시켰으나 *실제 클럭(200)*에서는 위반이었던 것이다(**[그림: `docs/timing/04_200mhz_earlier-build_wns+0.04_silent-fail-suspect.png`]**). 즉 그 latency 비교는 깨진 빌드끼리의 비교였으므로 폐기하였다. 교훈은 셋이다: ① `report_clocks`로 실제 period ≠ 요청 period인지 확인(스냅 탐지), ② **slow(signoff) corner의 양수 WNS만 신뢰**, ③ 타이밍이 깨진 HW 측정은 성능 근거로 쓸 수 없다.

**해결.** 이 깨달음이 방향을 정했다 — "reset 경로(−1.94)부터 닫자". 300 MHz 합성에서 conv2 broadcast를 닫은 뒤 남은 최대 위반이 바로 **단일 reset net**이었다: `rst_sync → BUFG → (fanout 41,323) → DSP/register`, **−1.94 ns, route 85%, die 전역**. 단일 net이 datapath 전 레지스터(약 41k)로 직접 fanout되어 BUFG 글로벌 라우팅으로 die 끝까지 가는 데 너무 오래 걸렸다.

두 가지 안을 검토했다. reset 부하 자체를 없애는 tie-0 방식은 **기능 거동을 바꾸고 fragile**하여 기각했다. 채택한 안은 **reset 복제 트리** — reset을 제거하지 않고 분배 구조만 바꾸므로 **기능이 완전히 불변**이다.

```verilog
// RTL/cnn_accelerator.v — async-assert / sync-deassert 유지한 registered 복제 트리
(* max_fanout = 32  *) reg rst_l1;     // trunk (few copies)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_l1   <= 1'b1; else rst_l1   <= rst_sync;
(* max_fanout = 128 *) reg rst_leaf;   // leaf (datapath 근처로 대량 복제)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_leaf <= 1'b1; else rst_leaf <= rst_l1;
wire rst = rst_leaf;
```

`max_fanout`이 합성기에게 `rst_sync(1) → rst_l1(~11) → rst_leaf(~323) → datapath(~41k)` 트리를 자동 생성시키고, 각 leaf 복제본을 자기 클러스터 근처에 배치하게 하여 high-fanout net을 짧은 local net 다수로 쪼갠다. async-assert이므로 모든 단이 reset을 즉시(스큐 0) assert하고, deassert만 +2 clk 균일 지연된다(전체 idle-start라 무해).

이후 잔여 위반을 단계적으로 닫았다. 진행표는 다음과 같다.

**[표 T4: 200 MHz WNS 마일스톤]**

| 단계 | WNS (ns) | Failing | 워스트 경로 | 조치 | 로그/캡처 |
|---|---|---|---|---|---|
| reset 트리 (초기 impl) | **−0.154** | 44 | `wl_inst/pe_id_reg → pe_load_en_dec_r` (route 82%) | reset −1.94 완전 소멸 | `05_..._wns-0.154.txt` |
| + phys_opt (default) | **−0.102** | 31 | `conv2/fsm/state → lb2/mem_reg/CE` (route 86%) | default phys_opt plateau | `06_..._wns-0.102_lb2-CE.txt` |
| + conv2 `shift_en` max_fanout=16 | **−0.098** | 1 | (lb2 cluster 거의 닫힘) | RTL 복제 (캡처 없음) | — |
| + phys_opt `-directive AggressiveExplore` | **+0.011** | **0** | — | **MET** | `07_..._MET_wns+0.011.txt` |

세 번째 행의 새 워스트는 conv2의 `shift_en`(line buffer clock-enable 생성)이었다. `state`·`kw_cnt`는 이미 `max_fanout=32`였으나 `shift_en`만 빠져 있어, 한 줄로 복제 속성을 부여하였다.

```verilog
(* max_fanout = 16 *) wire fsm_shift_en;   // RTL/conv2/conv2_engine.v — zero-latency, 기능 불변
```

마지막 한 끗은 phys_opt directive였다. default `phys_opt_design`은 −0.154→−0.102에서 plateau("WNS did not improve")였고, **`phys_opt_design -directive AggressiveExplore`**가 −0.098 → **+0.011(0 failing)**로 마감하였다.

> ⚠ **재현성 함정(필수 기록)**: 위 AggressiveExplore는 interactive phys_opt의 in-memory 결과다. impl을 재실행하면 이 결과가 사라지고 −0.098로 되돌아간다. 따라서 재현하려면 **impl strategy에 post-route phys_opt(AggressiveExplore)를 명시적으로 넣어야** 한다.

최종 결과는 **200 MHz timing CLOSED — WNS +0.011, TNS 0.000, WHS +0.002**다. 이는 slow(signoff) corner의 양수 WNS이므로 §5.1.5 앞부분의 −1.94 silent fail과 근본적으로 다른 정식 충족이다. 결과 사진은 다음과 같다.

- **[그림: 최종 timing 요약 `docs/timing/final_timing.png` / 로그 `07_..._MET_wns+0.011.txt`]**
- **[그림: power 리포트 `docs/timing/final_power.png`]** (수치 해석은 §6.2·§7.4)

> 관통 교훈(짧게, 상세는 §7): 이 설계의 datapath 타이밍 벽은 대부분 high-fanout 제어·reset net의 route delay였고(로직 깊이가 아님), 효과적인 처방은 `max_fanout`으로 드라이버를 클러스터 근처에 복제하는 것이었다. 또한 워스트 하나를 닫으면 다음이 노출되는 "양파 까기"가 반복되었다.

### 5.2 Winograd Track — 200 MHz 시도 끝에 171.42 MHz로 met

Winograd 엔진도 §5.1과 같은 closure 레버를 적용했으나, 곱셈을 줄이는 대신 transform network·gather 구조가 추가되어 **route congestion이라는 새로운 변수**가 생겼다. RTL은 시뮬레이션 bit-exact로 검증됐고 합성도 fit했지만, 목표였던 200 MHz는 끝내 닫지 못하고 **171.42 MHz에서 timing-met**으로 마무리했다. 200 MHz 시도 과정을 시간 순서대로 기술한다. **[표 T11: Winograd WNS 마일스톤]**

**합성 단계 — LUT overflow.** 첫 합성은 상수 ROM 기반 transform이 LUT를 78.7K까지 써(63.4K 초과) 배치 자체가 실패했다. 두 가지로 해결했다: ReLU 출력 범위 분석으로 데이터 비트폭을 줄이고(VW 16→14, MW 32→25, YW 36→28 등), baked ROM을 PS-writable BMG weight로 바꿔 LUT 부담을 BRAM으로 옮겼다. 결과 LUT 75.88%로 fit.

**라우팅 단계 — 병목을 한 겹씩 벗기다.** 진행은 §5.1과 동일한 "양파 까기"였으나 병목의 성격이 달랐다(`vivado_reports/` 폴더명이 단계를 보존한다).

- **−2.04 ns (`02_rb-broadcast`)**: row buffer write broadcast(fanout 312, route 93%)가 주범 → per-PE distributed LUTRAM으로 전환해 공유 net 제거.
- **−1.74 ns (`03_output-transform`)**: output transform의 20-level 조합 깊이가 노출 → OT를 1-cycle에서 4-stage 파이프라인으로 분할.
- **−0.41 ns (`04_wm-equiv-merge`)**: 합성기가 4-lane weight 레지스터를 하나로 equiv-merge해 fanout이 2,944로 폭증 → `(* keep, max_fanout *)`로 lane별 복제 보존.
- **−0.34 ns (`05_endgame-40ep`)**: 잔여 40 endpoint를 IT·tile6·wm·gather 4개 class로 층화.
- **−0.094 ns, 7 EP (`06_MBD-baseline`)**: 세 class(M/B/D)만 남음 — M은 25-bit 음수 누적의 carry chain, B는 tile6_q(2,304-bit)의 die-spanning scatter, D는 동일 25-bit 가산.

**한계에 부딪힘 — bisect와 floorplan 둘 다 실패.** −0.094를 닫기 위해 두 가지를 시도했고 둘 다 역효과였음을 정직하게 기록한다.

- **M carry-bisect (13+12 분할)**: M 경로는 닫혔으나(−0.094→0), +1 latency와 새 레지스터들의 배치 churn으로 **B class가 −0.088→−0.150으로 회귀**(`07_classB-reverted`)하고 Fmax가 196→187 MHz로 오히려 떨어졌다. → revert.
- **Floorplan(pblock 압축)**: gather→central-reduce 구조가 lane 입력 4-way fan-in과 글로벌 출력 fan-out을 동시에 갖는 net-bound 구조라, pblock으로 압축하면 한쪽 net이 반드시 늘어난다. 강제 압축 시 WNS가 −1.116으로 10배 악화 → 본질적으로 floorplan 부적합.

**현재 위치(정직한 결론).** 200 MHz는 한 병목을 닫으면 다른 곳이 터지는 "두더지 잡기"가 반복되어(bisect는 churn으로 Fmax 회귀, floorplan은 배치 붕괴) 끝내 닫지 못했고, **171.42 MHz로 fallback**했다. 그리고 **171.42 MHz에서는 timing이 완전히 닫혔다 — WNS +0.222 ns, TNS 0.000, 0 failing endpoint, "all user specified timing constraints are met"**(period 5.833 ns, MMCM VCO 한계가 정하는 이산 클럭). **[그림 F11: Winograd 171.42 MHz timing summary — `figures/existing/winograd_171.42MHz_timing.png`]** 즉 171.42 MHz는 추정이 아니라 **정식 timing-met 결과**이고, 200 MHz만 미완이다.

다만 **보드 실측은 수행하지 못했다** — 보드 제출 마감 시점에 200 MHz fallback이 확정되지 않아, 최종 Winograd 비트스트림의 HW bring-up·latency 측정을 하지 못했다. 따라서 Winograd의 1만 장 latency는 **시뮬레이션 bit-exact + implementation timing(171.42 MHz met) + TB 측정 cycle**로부터 추정한다: compute-bound 가정 시 약 `1,341 cyc × 10,000 / 171.42 MHz ≈ 78 ms`(feed 오버랩 무시), 만약 200 MHz가 닫혔다면 ~67 ms였을 것이다. 이 값들은 모두 보드 실측이 아닌 추정임을 명시한다.

### 5.3 두 트랙 종합

두 트랙 모두 timing closure에는 성공했으나 마무리가 다르다. Baseline은 **200 MHz MET(WNS +0.011 ns)이고 보드 실측까지 완료**(~98 ms)했고, Winograd는 200 MHz를 닫지 못해 **171.42 MHz MET(WNS +0.222 ns)으로 fallback했으며 보드 실측은 시간상 못 해 추정(~78 ms)**에 그친다. 두 트랙을 한 표로 대비한다. **[표 T12: Baseline vs Winograd closure — 클럭·WNS·검증수준·latency(실측/추정)]** 주목할 점은 **같은 closure 레버(`max_fanout` 복제, 파이프라인 분할, phys_opt directive)가 성격이 다른 두 설계에 모두 통했다**는 것이다 — 다만 Winograd는 gather 구조의 본질적 route 특성 때문에 baseline보다 마지막 구간을 닫기가 더 어려워, 같은 200 MHz 목표에 도달하지 못하고 한 단계 낮은 이산 클럭에서 멈췄다.

---

## 6. Results

> 줌 레벨 = **검증·측정**. 명세 Results 요구(기능 검증, 보드 util/power, 보드 실행 정확도·latency)를 다룬다. timing closure 서사 자체는 §5에 있으므로 여기서는 **측정 결과값**에 집중하고 최종 WNS는 §5에서 인용한다. **아래는 본문 초안.**

### 6.1 Baseline — 오버클럭 이전: 기능 검증

기능 검증의 기준은 PyTorch reference 모델(golden)이다. golden으로부터 레이어별 입력·기대출력을 hex로 생성하고, 각 레이어의 출력이 INT8 단위로 golden과 정확히 일치하는지(bit-exact)를 모듈별 테스트벤치와 전체 통합 테스트벤치로 확인한다. **[그림 F12: golden → hex → RTL bit-exact 검증 파이프라인]** 아래는 모듈별 검증 결과다 — 각 모듈은 PASS 로그와(해당되면) 동작 파형을 함께 싣고 핵심 동작을 한 줄로 해석한다.

#### 6.1.1 PE cell — 2²⁴ exhaustive
PE cell은 weight·activation 입력 조합 전체(2²⁴ ≈ 16.7M)에 대한 exhaustive 검증으로 SIMD packing이 **모든 INT8 경우에 bit-exact**(W1=−128 corner 포함)임을 증명했다. 이는 §2.2 packing 주장의 직접 근거다. **[그림 W1: pe_cell exhaustive PASS 로그]**

#### 6.1.2 Conv1 / Conv2 — 단위 TB (로그 + 파형)
Conv1·Conv2 각각의 단위 테스트벤치로 레이어 출력이 golden과 bit-exact임을 확인했다. 파형으로는 line buffer → window register로 3×3 윈도우가 매 사이클 생성되는 과정과 PE 누적 타이밍을 분석한다. **[그림 W2: conv1 PASS 로그 + 윈도우/누적 파형]** **[그림 W3: conv2 PASS 로그 + K_col 3-cycle 누적 파형]**

#### 6.1.3 FC / argmax — 단위 TB (로그 + 파형)
FC는 2,304→10 누적이 golden과 일치함을, argmax는 4-round tournament가 최댓값 인덱스를 올바르게(낮은 인덱스 우선 tie-break) 내는지 확인한다. 파형으로 logit 누적 완료 → argmax 4-cycle latency를 분석한다. **[그림 W4: fc PASS 로그 + logit 누적 파형]** **[그림 W5: argmax PASS 로그 + tournament 파형]**

#### 6.1.4 MaxPool — 단위 TB (로그)
MaxPool은 동작이 단순(2×2 조합 비교)하므로 PASS 로그만 싣는다. **[그림 W6: maxpool PASS 로그]**

#### 6.1.5 통합 TB & ping-pong
전체 파이프라인 통합 테스트벤치로 MNIST 이미지에 대해 logit이 bit-exact임을 확인하고, ping-pong bank toggle과 stage 간 핸드셰이크 타이밍을 파형으로 분석한다. **[그림 W7: 통합 TB PASS 로그 + ping-pong/handshake 파형]**

> 캡처 방침(부록 D.2): 각 모듈 [로그 캡처 + 파형 캡처 + 1줄 해석], 단 MaxPool은 로그만. 그림 W1~W7은 `figures/user/`.

### 6.2 Baseline — 오버클럭 이후: 보드 구현 & 실행

**Timing.** 200 MHz에서 timing closure를 완료했다(WNS +0.011 ns @ slow corner, MET). 단계별 closure 서사와 WNS 추적표(T4)는 §5.1에 있으며, 여기서는 최종 signoff 값만 인용한다.

**Resource utilization.** baseline은 DSP **226/240(94%)**(Conv2 192 + Conv1 18 + FC 16)을 쓴다. LUT / FF / BRAM을 포함한 전체 사용량을 표로 정리한다. **[표 T5]** *주의: DSP 226은 확인된 값이나, baseline 전용 LUT/FF/BRAM util 리포트가 별도로 없으므로 Vivado에서 baseline implementation의 util을 재생성해 정확 수치를 기입한다(부록 C TODO). 그 전까지 LUT/FF/BRAM 수치는 provisional.* **[그림: util 리포트 캡처]**

**Power (명세 우선순위 #2).** `docs/timing/final_power.png` 기반으로 total / dynamic / static(W)을 표기한다. 명세 p.7의 요구대로 **power 리포트 setup을 default에서 변경하지 않고** 측정했음을 명시한다. 가능하면 150 MHz와 200 MHz 두 시점의 power를 함께 제시해 오버클럭 전후를 비교한다(트레이드오프 해석은 §7.4). **[표 T10: 클럭별 power]** *주의: 정확 수치는 png에서 확인 후 기입.*

**보드 실행 결과.** clean 빌드(WNS +0.011)에서 측정했으므로 수치 자체가 신뢰 가능하다.

- **정확도(SW 대비)**: MNIST 10,000장에 대해 **10,000 / 10,000 일치**(100%).
- **Latency**: 최초 200 MHz 실측 **108.9 ms**(10,896,290 cycle @ 100 MHz 타이머). 이 108.9 ms는 100 MHz baseline(0.188 s) 대비 1.72×, 150 MHz(0.128 s) 대비 1.17×이다. 이후 Vitis feed-overlap 최적화로 **약 98 ms**까지 더 단축했다(0.188 s 대비 1.92×). 즉 클럭만으로는 1.72×, feed 최적화를 더하면 1.92×다.
- **End-to-end 진행**: 점진적 최적화에 따른 latency 변화를 표로 정리한다. 검증된 지점은 100 MHz baseline 0.188 s → 150 MHz 0.128 s → 200 MHz 108.9 ms → feed-overlap 후 약 98 ms이다. **[표 T6]** *주의: ping-pong·AXI burst 등 중간 단계의 개별 수치는 results_gallery·overclock_journey와 대조해 확정(검증 안 된 값은 표에서 제외).*
- **프로파일**: 실측 로그상 in-CDMA(blocking) 입력 feed가 전체의 72%(7,905,500 cycle, 100 MHz 도메인)를 차지한다. 가속기 클럭을 2배로 올려도 compute slice만 압축되므로 1.72×에 그쳤다 — 즉 다음 병목이 연산이 아니라 **PS-PL feed**임을 데이터가 가리킨다(해석은 §7.6). **[그림: 보드 실측 캡처 `docs/timing/08_*` / `result_04_overclock_200MHz_vitis_overlap_hw.png`]**

### 6.3 Winograd — 오버클럭 이전: bit-exact 검증

Winograd 데이터패스는 시뮬레이션 정수 검증을 통과했다. **Winograd를 적용한 top-module TB**는 logit bit-exact + bram_output readback 모두 **100/100 PASS**(`FINAL: results 100/100`, throughput 132,759 cyc total, avg 1,341 cyc/img, "PASS — logit bit-exact + bram_output readback, overlap")이다. **[그림 F10: Winograd top-module TB 결과 캡처 (100/100, avg 1,341 cyc/img)]** Conv1 2× rebalance gate는 별도로 40/40 bit-exact(`tb_cnn_accelerator_multi`)이며, 두 결과는 서로 다른 테스트벤치이므로 혼동 없이 분리해 표기한다.

검증 기준은 정수 golden이다 — 하드웨어의 정수 데이터패스는 정수 reference와 정확히 0 오차로 일치한다(bit-exact). 한편 float 골든 모델 내부에서 나오는 `err < 5e-16`은 부동소수 reference 자체의 반올림 오차일 뿐 하드웨어 비교값이 아니므로, 둘을 분리해 서술한다. 전체 10,000장은 `1_complex_winograd_f(4,3).py` 정수 golden 기준 bit-exact 100%로 확인했다.

cycle 분석으로는 Conv2가 직접 conv 대비 줄어들고 Conv1 2× rebalance 후 두 레이어가 균형을 이룬다. **[표 T3: 병목 이동 — §7.5와 공유]**

### 6.4 Winograd — 오버클럭 이후: util & 비교

합성 결과 자원 사용량은 LUT 75.88%(48,110/63,400), FF 49.07%(62,221/126,800), **DSP 98.33%(236/240)**, BRAM 41.85%(56.5/135)이다(`vivado_reports/01_synth_area_lut76/` 및 hierarchical util). DSP가 거의 포화 상태로, Winograd multiply array(184) + Conv1 2×(36) + FC(16)가 예산을 빠듯하게 채운다.

timing은 **171.42 MHz에서 met**(WNS +0.222 ns, 0 failing endpoint)으로 닫혔다(단계별 서사는 §5.2). 다만 **보드 실측은 수행하지 못했다**(보드 제출 마감 시점에 fallback 미확정). 따라서 정확도·latency는 **시뮬레이션 검증 + implementation timing + cycle 추정**으로 보고한다: 시뮬레이션에서 bit-exact(100/100, §6.3)이므로 보드에서도 baseline과 동일한 10,000/10,000이 기대되며, latency는 `1,341 cyc × 10,000 / 171.42 MHz ≈ 78 ms`(compute-only, feed 무시)로 추정된다 — **모두 추정이며 보드 실측이 아님을 명시**한다.

power는 default setup으로 측정 시 baseline 대비(DSP 98% vs 94%, LUT 증가) 구성이 다르나, Winograd는 보드 측정이 없어 합성/implementation 추정 power만 제시하거나 "보드 측정 미수행"으로 정직하게 표기한다.

마지막으로 Baseline과 Winograd를 한 표로 대비한다(클럭·WNS·검증 수준·DSP·cycle·latency를 **실측(baseline)/추정(winograd)**으로 구분 표기). **[표 T7: Baseline vs Winograd]**

---

## 7. Discussion

> 줌 레벨 = **해석**. 명세가 명시적으로 요구하듯 단순 결과 요약이 아니라 본인의 분석·해석을 담는다. 오버클럭 단계별 서사는 §5로 이관했으므로, 여기서는 설계 결정의 재평가, 디버깅 사례의 일반화, power 트레이드오프, 한계를 다룬다. **아래는 본문 초안.**

### 7.1 DSP48E1 SIMD packing의 재평가 — 특히 -128 보정

SIMD packing은 본 설계에서 가장 효과가 컸던 결정이다. 한 DSP가 두 INT8 곱을 처리하므로 같은 240개 예산으로 사실상 두 배의 연산을 얻었고, 이는 Conv2를 192 DSP로 닫을 수 있게 한 직접적 전제였다.

다만 -128 corner case 보정에 대해서는 솔직한 위치 설정이 필요하다. 이론상 `W1=-128 ∧ W0<0`에서 25비트 표현이 overflow하므로 산술 보정항을 설계에 포함했으나, **본 과제의 실제 제공 가중치에는 -128이 존재하지 않아 이 보정 경로는 실측에서 한 번도 활성화되지 않았다**(§2.2 그림 F9의 전수 검증: 세 레이어 모두 -128 cnt=0). 따라서 이 보정을 "실측 성능 기여"로 과대평가해서는 안 된다. 그 가치는 두 가지 다른 측면에 있다. 첫째는 일반성이다 — 임의의 INT8 가중치(재학습된 다른 모델 포함)에 대해서도 bit-exact를 보장하므로, 이 PE는 본 과제에 한정되지 않는 재사용 가능한 빌딩 블록이다. 둘째는 선행연구 대비 위치다 — Xilinx WP486은 27비트 A 포트를 가진 DSP48E2 전용이고 Vestias(FPL'17)는 -128에서 손상이 발생하는데, 본 기법은 더 좁은 DSP48E1(25비트)에서 산술 보정만으로 전 케이스를 무손상 처리한다. 2²⁴ exhaustive 검증(§6.1)이 이 일반성을 뒷받침한다. 실제 데이터엔 -128이 없었음을 명시하는 것이 오히려 주장의 신뢰도를 높인다.

### 7.2 디버깅 사례 1 — AXI-Lite write hang

CSR read는 정상인데 첫 CSR write에서 MicroBlaze가 무한 hang하는 문제가 있었다. 원인은 Xilinx "Create AXI4 Peripheral → Lite" 템플릿의 핸드셰이크 버그였다 — write address(AW)와 write data(W)가 도착하는 순서를 slave FSM이 암묵적으로 가정하고 있어서, W가 AW보다 먼저 오는 경우(AXI 규약상 합법) FSM이 멈춰 BVALID를 발행하지 못했다. 해결은 `AWVALID && WVALID`가 동시에 성립할 때만 ready를 assert하도록 핸드셰이크를 고친 것이다. **[코드 발췌 C9]**

이 사례의 일반적 교훈은 **AXI interconnect는 W를 AW보다 먼저 보낼 수 있으며, slave는 채널 도착 순서를 가정해서는 안 된다**는 것이다. 벤더 템플릿이라고 해서 모든 합법 시나리오를 처리한다고 믿을 수 없다는 점도 함께 확인했다. `docs/axi_lite_write_hang_fix.md`

### 7.3 디버깅 사례 2 — NBA register race

이 버그는 발현 양상 자체가 교훈적이었다. 단위 테스트(maxpool 단독 40장)는 통과하는데 통합 테스트(conv1→conv2→maxpool 40장)에서만 img 1부터 거의 모든 픽셀(~115/144)이 틀렸다. 원인을 추적하니 maxpool의 image 1 write_done이 conv2의 image 1 write_done보다 82 cycle 빨랐다 — 즉 maxpool이 conv2가 아직 c2pool 버퍼에 쓰지 않은 영역을 읽고 있었다.

근본 원인은 NBA(non-blocking assignment) 타이밍이었다. maxpool FSM이 핸드셰이크 카운터 `prior_diff`를 같은 사이클에 갱신(NBA)하면서, 동시에 그 값을 조합 조건 `data_ready = (prior_diff < 0)`으로 FSM 전이에 썼다. NBA는 사이클 끝에 갱신되므로 조건은 *이전 사이클의 값*을 보게 되고, 그 결과 한 박자 이른 잘못된 전이가 일어났다. 단위 테스트가 이를 놓친 이유는, 단독 TB가 입력 pulse를 인위적으로 벌려 주어 race window가 생기지 않았기 때문이다 — engine 간 자연스러운 타이밍에서만 드러나는 결함이었다. 해결은 현재 사이클의 trigger를 반영한 조합값 `prior_diff_next`로 조건을 판정한 것이다. **[코드 발췌 C10]**

일반적 교훈은 **counter 기반 조건으로 전이를 결정하는 FSM은, 그 counter가 같은 사이클에 갱신될 때 반드시 `*_next` 조합값을 써야 한다**는 것이다. 또한 이 사례는 단위 테스트만으로는 engine 간 상호작용 결함을 못 잡으므로 통합 테스트가 필수임을 보여준다. `docs/handshake_counter_nba_race.md`

> 주: Direct/Winograd의 오버클럭 단계별 진단 서사(BMG register, fanout, silent timing failure, reset tree, phys_opt 등)는 §5 Optimization Journey에 있다. 그 과정에서 얻은 일반 교훈(high-fanout net의 route delay가 벽이며 `max_fanout` 복제가 처방, positive WNS @ slow corner만 신뢰)도 §5.1에 정리했다.

### 7.4 Power 분석 (명세 우선순위 #2)

명세는 latency 다음으로 power를 중시하고(p.6), power 리포트 setup을 default에서 바꾸지 말라고 못박는다(p.7). 따라서 power를 단순 수치(§6.2)로 끝내지 않고 트레이드오프 관점에서 해석한다.

먼저 오버클럭과 power의 관계다. 클럭을 150에서 200 MHz로 올리면 dynamic power는 switching 빈도에 비례해 증가한다. 그러나 명세 #2의 기준은 "throughput을 손해 보지 않는 선에서 최소 power"이므로, latency가 실제로 줄어드는 한 클럭 상승은 #2 위반이 아니라 #1(latency 최우선)과 정합한다. 더 의미 있는 지표는 **단위 추론당 에너지(energy per inference = power × latency)**다 — 클럭을 올려 latency가 짧아지면 전력이 다소 늘어도 추론 한 건당 에너지는 오히려 줄어들 수 있다. 가능하면 이를 수치로 제시한다.

다음은 Baseline과 Winograd의 power 비교다. Winograd는 DSP 점유가 더 높고(94%→98%) transform network 때문에 LUT가 늘어 정적/동적 power 구성이 다르다. 핵심 질문은 곱셈 수 3.13× 감소(곱셈을 가산으로 치환)가 연산 에너지를 실제로 줄이는지, 아니면 transform 오버헤드가 그 이득을 상쇄하는지다. 이는 측정값으로 평가해야 하며, 보드 closure 전이면 미측정으로 정직하게 표기한다. 모든 수치는 default setup 측정임을 명시해 신뢰성을 담보한다.

### 7.5 설계 통찰 — 병목의 이동과 분산 제어

본 프로젝트를 관통하는 통찰은 **지엽적 최적화가 전역 병목을 이동시킨다**는 것이다. 직접 conv 단계에서는 Conv2(약 1,799 cyc)가 병목이고 Conv1은 1,634 cyc였다. Conv2를 Winograd로 약 1,341 cyc까지 줄이자 이번에는 **Conv1(1,634 cyc)이 새 병목**이 되었다 — Conv2만 빠르게 해서는 전체 throughput이 1,634에 묶인다. 그래서 Conv1을 2× rebalance해 837 cyc로 낮췄고, 그 결과 병목은 다시 Winograd-Conv2(약 1,341 cyc)로 돌아가 파이프라인 floor가 1,634에서 약 1,341로 내려갔다. 즉 두 레이어가 정확히 같아지는 것이 목표가 아니라, *더 느린 쪽을 더 빠른 쪽 아래로 끌어내려* 전역 floor를 낮추는 것이 핵심이다. 이 병목 이동을 정량적으로 정리한다. **[표 T3: 직접 / Winograd만 / +Conv1 2×, 각 단계의 Conv1·Conv2 cyc와 전역 floor]**

또 하나는 분산 FSM 제어의 이점이다. 중앙 컨트롤러 대신 각 engine이 자체 FSM과 핸드셰이크로 동기하는 구조(§3.0.3)는, 제어 신호의 거대 fanout과 그로 인한 timing 부담을 구조적으로 회피한다. §5의 timing closure에서 반복적으로 문제가 된 것이 high-fanout 제어 net이었음을 떠올리면, 애초에 중앙 컨트롤러를 피한 결정이 closure를 비교적 수월하게 만든 한 요인이었다고 평가할 수 있다.

### 7.6 한계와 Future Work

가장 중요한 한계는 **병목이 연산에서 데이터 전송으로 이동했다**는 점이다. 클럭을 100에서 200 MHz로 올렸지만 latency는 2배가 아니라 1.72×만 줄었다. 실측 프로파일상 전체 시간의 72%가 100 MHz 도메인의 blocking CDMA 입력 feed에 쓰이기 때문이다(§6.2). 가속기 클럭을 올려도 compute slice만 압축될 뿐 feed 시간은 그대로이므로, 설계가 compute-bound에서 memory/feed-bound로 전이한 것이다. 따라서 다음 레버는 연산이 아니라 **feed overlap**(non-blocking/prefetch CDMA + 입력 bank 2개 초과)이다. 이것이 선행되어야 Winograd의 연산 감소가 비로소 end-to-end latency로 환원된다.

둘째, Winograd는 200 MHz를 닫지 못하고 171.42 MHz로 fallback했으며(§5.2), 무엇보다 **보드 실측을 수행하지 못했다** — 보드 제출 마감 시점의 시간 제약 때문이다. 따라서 Winograd의 성능은 시뮬레이션 bit-exact + 171.42 MHz timing-met + cycle 추정(~78 ms)으로만 보고되며, 보드 bring-up과 200 MHz closure(phys_opt·floorplan·carry-select)가 명확한 후속 작업이다.

셋째, §7.1에서 보았듯 -128 보정의 가치는 실측 성능이 아니라 일반성 측면에서만 유효하다 — 다른 가중치로 재학습하는 경우에 의미를 갖는다.

---

## 8. Conclusion

> 아래는 본문 초안.

본 프로젝트는 Arty A7-100T 위에서 MNIST 10,000장을 분류하는 INT8 CNN 가속기를 설계하고, end-to-end latency 최소화를 목표로 최적화하였다. 결과는 두 갈래로 정리된다.

**검증 완료된 baseline.** 명세의 INT8 직접 컨볼루션을 비트-정확하게 구현하고 200 MHz로 timing closure(WNS +0.011 ns @ slow corner)하여, MNIST 10,000장에 대해 **10,000/10,000 정확도**와 **약 98 ms** latency를 보드에서 실측하였다. 이 과정에서 가장 큰 작업은 −8.6 ns에서 +0.011 ns까지 닫아간 timing closure 여정(§5)이었으며, 그 핵심 통찰은 이 칩의 타이밍 벽이 로직 깊이가 아니라 high-fanout 제어·리셋 net의 route delay에 있었고 `max_fanout` 드라이버 복제가 일관된 처방이었다는 것이다.

**제안 알고리즘.** Conv2가 곱셈의 90%를 차지한다는 분석에서 출발해, (1) DSP48E1 한 개로 두 INT8 곱을 처리하는 SIMD packing, (2) 곱셈을 직접 conv 대비 3.13× 줄이면서 INT8 bit-exact를 유지하는 complex Winograd F(4×4, 3×3), (3) 그로 인해 이동한 병목을 맞추는 Conv1 2× rebalance를 도입하였다. Winograd 데이터패스는 시뮬레이션에서 bit-exact로 검증되었고 implementation은 **171.42 MHz로 timing-met**(200 MHz는 두더지 잡기식 병목 연쇄로 미달)이다. 다만 보드 제출 마감 시점의 시간 제약으로 **보드 실측은 수행하지 못해**, 1만 장 latency는 cycle 추정(~78 ms @171.42 MHz)으로만 보고한다.

마지막으로, 본 설계의 다음 한계는 연산이 아니라 데이터 전송에 있다. 클럭을 두 배로 올려도 latency가 1.72×만 줄어든 것은 전체 시간의 72%가 PS-PL feed에 묶여 있기 때문이며, 따라서 Winograd의 연산 이득을 온전히 얻으려면 feed overlap이 선행되어야 한다 — 이는 향후 작업의 분명한 방향이다.

## 9. References
- 명세서(AS2 announcement), 수업 자료(week 9 CSR), Winograd 원전(Lavin & Gray 2016 등), Xilinx WP486 / UG479(DSP48E1), Vestias FPL'17, PyTorch. (실제 인용 문헌은 작성 시 확정.)

## Appendix (선택)
- 전체 CSR map, BMG 파라미터 표, 추가 파형, 전체 모듈 계층도.

---

## 부록 A. 코드 발췌 후보 목록 (Typst에 넣을 것)

| # | 발췌 대상 | 파일 | 뒷받침 주장 | 섹션 |
|---|---|---|---|---|
| C1 | P0/P1 추출 + -128 보정 | `RTL/core/pe_cell.v` | SIMD packing이 bit-exact (보정 가치=일반성, §7.1) | 2.2 / 3.A.1 / 7.1 |
| C2 | `truncate_relu` >>10+sat+ReLU | `RTL/core/truncate_relu.v` | 명세 양자화 메커니즘 정확 재현 | 1.4 / 3.A.4 |
| C3 | kcol_accumulator 누적 | `RTL/conv2/kcol_accumulator.v` | Conv2 24b K_col 시퀀셜 누적 구조 | 3.A.1 / 2.3.3 |
| C4 | CDC pulse/bit sync | `RTL/core/cdc_*.v` | 100/PL 도메인 안전 횡단 | 3.0.1 |
| C5 | reset 2-tier tree | `RTL/cnn_accelerator*.v` | 오버클럭 RTL 변경 | 3.B(안내) / 5.1.5(상세) |
| C6 | main.c inference loop | `vitis/main.c` | PS는 전송/제어만(명세 제약) | 3.A.3 |
| C7 | wino_truncate `>>>14` 결합 | `RTL/conv2_winograd/wino_truncate.v` | Winograd가 직접 conv와 동일 양자화 | 4.A.1 |
| C8 | argmax tournament | `RTL/fc/fc_argmax.v` | 타이밍 위한 4-round 재구성 | 3.A.1 / 5.1.4(상세) |
| C9 | AXI-Lite AWVALID&&WVALID handshake | `RTL/control_status_register/axi_inner_ref.v` | write hang 수정 | 7.2 |
| C10 | `prior_diff_next` 조합 판정 | `RTL/maxpool/maxpool_fsm.v` | NBA race 수정 | 7.3 |

## 부록 B. 그림/표 목록

- F1 타겟 CNN 구조도 · F2 PS-PL 블록도 · F3 stage 핸드셰이크/핑퐁 · F4 단일 이미지 데이터 이동 경로
- W1/W2 시뮬 파형 · 보드 실측 캡처(docs/timing/08_*) · util/power 리포트 캡처
- T1 핑퐁 버퍼 · T2 CSR map · T3 병목 이동(§7.5) · T4 WNS 마일스톤(§5.1) · T5 util · T6 end-to-end latency 진행 · T7 baseline vs winograd
- **T8 곱셈 수→비율→이상 DSP(비정수)(§2.3.2) · T9 병렬화 옵션(144 vs 192 vs …) vs DSP예산·packing·누적단순성→192(§2.3.3) · T10 클럭별 power(150/200MHz, default setup)(§6.2/§7.4)**
- **T11 Winograd WNS 마일스톤(−2.04→−1.74→−0.41→−0.34→−0.094, M/B/D class)(§5.2) · T12 Baseline vs Winograd closure 종합(§5.3)**
- 캡처(Winograd): `winograd_testbench_100image_result.png`(100/100 검증), `vivado_reports/03~07/*.png`(WNS 단계), `vivado_reports/01_synth_area_lut76/`(util)
- **의사코드 블록(§2.3.1): Conv1 / Conv2 / FC 연산 정의 중첩루프 3개**

## 부록 C. 작성 시 직접 확인할 항목 (TODO)
1. **Power 수치**: `docs/timing/final_power.png` 열어 total/dynamic/static W 정확 기입.
2. **Baseline util 정확 수치**: 별도 .rpt 없으면 Vivado에서 baseline implementation util 리포트 재생성.
3. 학번/팀번호로 파일명 확정: `TAS2_T#_김도현_학번.pdf`.
4. References 실제 문헌 확정.
5. 파형 캡처가 부족하면 시뮬 재실행해 핵심 구간 캡처.
6. (확정됨) 실제 가중치에 -128 없음 → §7.1에서 packing 보정을 "일반성" 가치로 서술, "실측 성능 기여"로 과대평가 금지.
7. §5.1 단계별 서사 작성 시 docs/timing/*.txt, overclock_journey, WINOGRAD_200MHZ_CLOSURE_PLAN에서 사용 명령/directive 정확 인용.
8. (확정됨, RTL 대조) **Conv2 축 명명 = 언롤 K_row(KH=3) / 시퀀셜 K_col(KW=3, kcol_accumulator).** 보고서 전체에서 이 명명 고정. (`conv2_engine.v` L273/L359/L278 근거.)
9. (확정됨) 144 = IC8×K9×SIMD2 / 192 = OC_pair8×IC8×K_row3 — 산술 명시.
10. (확정됨) Winograd 검증 수치: Conv2 engine 100/100, Conv1_2x 40/40, golden 10000장. "40/40을 full-pipe로" 쓰지 말 것. float golden err 5e-16 ≠ HW bit-exact(0) — 분리.
11. (확정됨) DSP48E1 multiplier = **25×18**. "16×25" 표기 금지.
12. (확정됨) §3.B 오버클럭 서사 → (b) 독립 §5 Optimization Journey 섹션으로 끌어올림.
13. 최종 PDF에서 §3.A.*/§4.A.* 재번호 일관성, §0(전략)은 제출 제외·Abstract 별도 작성 재확인.
14. §5.1 본문 초안 완료(평서체). §5.2/§5.3 Winograd 트랙도 자료(docs/winograd, vivado_reports) 정독 후 작성 완료.
15. §2 본문 초안 완료(평서체, T8 이상 DSP 검산: Conv1 15.9/Conv2 216.6/FC 7.5).
16. (Reader Test 통과·반영) DSP 총합 정정: **FC=16**(8 아님) → baseline 192+18+16=**226/240**, Winograd 184+36+16=**236/240**(hierarchical util 근거). C8 cross-ref 5.1.2→5.1.4 수정. Conv2 cyc: 순수연산 1,728 + fill/drain = floor 1,799 명시. 병목이동 서술 정정(837 vs 1,348 "균형"이 아니라 floor 인하). 1.72×=108.9ms 빌드 / 1.92×=98ms(feed) 분리. §1.6에 F(2,3) 수치 예시 추가. §2.7에 46분해용 그림 F5 명시.
17. (Reader Test 잔여 — 본문 작성 시) §2.7 G·Bᵀ·Aᵀ 행렬 실제 채우기(46 곱 분해의 시각적 근거), §2.2 P0/P1 보정에 수치 예시 1개, util T5 LUT/FF/BRAM provisional → Vivado 재생성, References(§9)·Power(T10) 수치 확정.

## 부록 D. 자산 매니페스트 (Typst 변환 시 #figure 연결용)

> **폴더 구조**: 보고서 산출물·자산은 최상위 **`report/`**에 모음 — `report/TAS2_report_plan.md`(본 계획서), `report/report.typ`(본문, 작성 예정), `report/TAS2_T#_김도현_학번.pdf`(최종), `report/figures/{existing, user, diagrams}/`.
> 그림 경로는 `report.typ` 기준 상대경로 **`figures/...`**로 적는다(이미 본문 갱신 완료). 원본은 `docs/`에 그대로 두고 보고서용만 `figures/existing/`에 복사.
> 출처 3분류: **A=이미 있음**(figures/existing·diagrams) · **B=사용자 캡처**(figures/user) · **C=사용자 사진 제공 예정**.

### D.1 이미 존재 (A) — `figures/existing/`·`figures/diagrams/`에 복사 완료

| 그림 | figures/ 경로 | 원본 위치 | 본문 |
|---|---|---|---|
| F6 sliding-window 재사용 | `diagrams/sobel_pipeline_dataflow.svg` | (업로드) | §1.4 |
| F7 DSP48E1 구조 | `existing/dsp48e1_structure.png` ✓ | (업로드) | §2.2 |
| F8 SIMD packing 비트맵 | `existing/simd_packing_bitmap.png` ✓ | (업로드) | §2.2 |
| F9 weight -128 부재 검증 | `existing/weight_no128_check.png` ✓ | (업로드) | §2.2/§7.1 |
| F10 Winograd top-module TB(100/100) | `existing/winograd_testbench_100image_result.png` | docs/overclock/winograd 외 | §6.3 |
| F11 Winograd 171.42MHz timing met | `existing/winograd_171.42MHz_timing.png` | docs/overclock/winograd/ | §5.2/§6.4 |
| P1 Clocking Wizard 블록 | `existing/clk_wiz.png` | docs/clk_wiz.png | §5.1.1 |
| WNS −8.6 | `existing/01_pre-pipeline_wns-8.6.png` | docs/overclock/direct/timing/ | §5.1.4 |
| WNS −2.99 | `existing/02_300mhz_conv2-broadcast_wns-2.99.png` | 〃 | §5.1.4 |
| WNS −2.454 / −2.187 | `existing/03_300mhz_step1-replication_wns-2.454.png`, `..._step1b-step2_wns-2.187.png` | 〃 | §5.1.4 |
| silent-fail 의심 빌드 | `existing/04_200mhz_earlier-build_wns+0.04_silent-fail-suspect.png` | 〃 | §5.1.5 |
| 150MHz timing | `existing/150_timing.png` | 〃 | §5.1.4 |
| 최종 200MHz timing(+0.011) | `existing/final_timing.png` (+로그 `07_..._MET_wns+0.011.txt`) | 〃 | §5.1.5/§6.2 |
| 최종 power | `existing/final_power.png` | 〃 | §6.2 |
| baseline HW 결과 | `existing/result_04_overclock_200MHz_vitis_overlap_hw.png` | docs/overclock/direct/ | §6.2 |
| Winograd util(synth) | `existing/winograd_utilization.png` | docs/ | §6.4 |
| BMG output register 설정 | (docs/ip_spec/bram_*/*-portA.png 직접 참조 or 복사) | docs/ip_spec/ | §5.1.3 |
| Winograd WNS 단계 캡처 | (docs/overclock/winograd/02~10/ 직접 참조) | docs/overclock/winograd/ | §5.2 |

> ※ figures/existing 복사 완료(총 16장): F7·F8·F9·F10·F11·P1·WNS 01~04·150·final_timing·final_power·baseline HW·winograd util. 인라인 업로드 3장(F7/F8/F9)도 저장·rename 완료.

### D.2 사용자 캡처 필요 (B) → `figures/user/`

- **모듈별 TB 결과(§6.1.1~6.1.5)** — 각 모듈 **로그 + 파형 + 1줄 해석**, maxpool은 로그만. 파일은 `figures/user/`에 그림 번호대로:
  - W1 pe_cell exhaustive PASS 로그 (§6.1.1)
  - W2 conv1 PASS 로그 + 윈도우/누적 파형 · W3 conv2 PASS 로그 + K_col 누적 파형 (§6.1.2)
  - W4 fc PASS 로그 + logit 누적 파형 · W5 argmax PASS 로그 + tournament 파형 (§6.1.3)
  - W6 maxpool PASS 로그(로그만) (§6.1.4)
  - W7 통합 TB PASS 로그 + ping-pong/handshake 파형 (§6.1.5)
  - F12 검증 파이프라인 다이어그램(golden→hex→RTL) — 필요 시 사용자 제작 or 간단 도식
- **P2 Clocking Wizard phase 정렬 체크** 캡처 → §5.1.1
- **baseline 전용 util 리포트**(LUT/FF/BRAM) 재생성 → §6.2 T5 (현재 provisional)
- **power 정확 수치** final_power.png에서 판독 → §6.2 T10

### D.3 사용자 사진 제공 예정 (C) → `figures/diagrams/`

- F1 타겟 CNN 구조도, F2 PS-PL 블록도, F3 핸드셰이크/핑퐁+FSM, F4 단일 이미지 데이터 이동, F5 Winograd 보간점 격자 → **사용자가 사진/SVG 제공 예정**(제가 작성 안 함).
- §2.7 G·Bᵀ·Aᵀ 행렬 실제 값(46 곱 분해 근거).
