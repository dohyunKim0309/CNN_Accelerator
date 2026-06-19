#import "../helpers.typ": *

= Introduction & Theory

== 서론

본 프로젝트의 목표는 MNIST 손글씨 숫자 10,000장을 분류하는 CNN 추론 가속기를
FPGA(Arty A7-100T) 위에 구현하는 것이다. 평가의 1순위는 10,000장 전체에 대한
*end-to-end latency 최소화*이고, 그 다음으로 전력과 자원 사용량을 고려한다.
명세상 모든 신경망 연산은 PL(Programmable Logic)에서 수행되어야 하며,
PS(MicroBlaze)는 메모리 read/write와 start/done 제어, 그리고 타이머 측정만 담당한다.

본 보고서가 답하는 세 가지는 가속기의 전체 아키텍처, 200 MHz timing closure에 이르는
문제해결 과정, 그리고 직접 컨볼루션 대비 곱셈을 줄이는 제안 알고리즘(complex Winograd)이다.

== CNN 기본 연산과 타겟 네트워크

타겟 네트워크는 두 개의 컨볼루션 레이어, 하나의 max-pooling, 하나의
fully-connected 레이어로 구성된다. 각 컨볼루션은 3×3 커널, stride 1, zero-padding
없음이므로 출력의 높이·너비가 입력보다 2씩 줄어든다. 데이터 흐름은 다음과 같다.

```
Input (1,28,28) -> Conv1 (8,1,3,3) -> ReLU -> (8,26,26)
                -> Conv2 (16,8,3,3) -> ReLU -> (16,24,24)
                -> MaxPool 2x2 -> (16,12,12)
                -> Flatten (W->H->C) -> 2304
                -> FC (2304->10) -> argmax -> class(0~9)
```

#figbox("figures/existing/target_cnn_architecture.png",
  [그림 F1: 타겟 CNN 구조도 (Input→Conv1→Conv2→MaxPool→FC→argmax)], w: 95%)

각 연산의 정의는 표준 그대로다. 2D 컨볼루션은 3×3 윈도우와 커널의
MAC(multiply-accumulate), ReLU는 음수를 0으로 클리핑, MaxPool은 2×2 영역의 최댓값,
FC는 2,304차원 입력과 (10×2304) 가중치의 행렬-벡터곱이다.

곱셈(MAC) 수를 레이어별로 세면 Conv1 48,672회(6.6%), *Conv2 663,552회(90.2%)*,
FC 23,040회(3.1%)로, Conv2가 연산의 90% 이상을 차지한다.

== MLP / Fully-Connected와 분류

마지막 FC 레이어는 MaxPool 출력 (16,12,12)을 width→height→channel 순으로 평탄화한
2,304차원 벡터를, (10×2,304) 가중치 행렬과 곱해 10개 클래스의 logit을 만든다.
그 중 최댓값의 인덱스(argmax)가 예측 숫자다. 이는 단층 퍼셉트론(MLP의 한 층)의
형태이며, 본 가속기는 이 행렬-벡터곱과 argmax를 PL에서 수행한다.

#figbox("figures/existing/maxpool_to_fc_computation.png",
  [그림 F1b: MaxPool 출력의 flatten(W→H→C)과 FC 입력 구성], w: 88%)

== Line-buffer 기반 Sliding-Window 스캔 <sec-linebuffer>

본 프로젝트의 컨볼루션 엔진은 입력 스트리밍에 line-buffer sliding-window 구조를 쓴다.
이는 이전 과제의 Sobel edge detection IP에서 검증된 구조를 재사용한 것이다.

BRAM에서 픽셀을 *raster-scan(한 클럭에 한 픽셀)* 으로 읽고 이를 line buffer 여러
개에 직렬로 통과시키면, 매 클럭에 *3×3 윈도우 하나* 가 완성된다(3×3 커널의 경우
line buffer 2개와 9개의 윈도우 레지스터가 필요하다). 일단 윈도우가 만들어지면 그
안의 9개 탭은 윈도우 레지스터에 모두 동시 가용하다.

#figbox("figures/diagrams/sobel_pipeline_dataflow.svg",
  [그림 F6: Sobel 파이프라인의 윈도우 shift 데이터 재사용], w: 70%)

이 구조의 중요한 점은 *한 번에 출력 한 행(OH)씩 진행한다* 는 것이다. 따라서 여러
출력 행을 동시에 계산하는 *OH 방향 병렬화* 는 line buffer를 갈래내거나 윈도우
레지스터를 복제하고 주소·valid 로직을 다중화해야 하므로 추가 비용이 든다. 이
비대칭은 @sec-dsp-alloc 에서 OH를 병렬 축으로 쓰지 않은 근거가 된다. 다만 이
비용은 _윈도우를 만드는_ 단계에 대한 것이며, 이미 만들어진 윈도우 _내부_ 의 커널
축 선택과는 무관하다.

== INT8 Quantization 이론 <sec-quant>

타겟 네트워크는 signed 8-bit 정수로 양자화되어 학습된 파라미터로 제공된다.
입력 이미지도 원래의 unsigned 8-bit(0~255)에서 signed 8-bit로 전처리된 값으로 주어진다.

추론 중 각 레이어의 누적은 오차를 줄이기 위해 비트를 확장한 정수(본 설계에서는
24-bit)로 수행하고, 출력 직전에 다음 규칙으로 다시 signed 8-bit로 절단한다:
*LSB 10비트를 산술 우측 시프트(`>>10`)한 뒤, 결과가 +127을 넘으면 127로, −128
미만이면 −128로 saturation하고, 하위 8비트를 출력으로 취한다.* 컨볼루션 뒤에는
ReLU가 결합되어 하한이 0이 된다.

#figbox("figures/existing/bit_truncation_saturation_for_8bit_quantization.png",
  [그림 F1c: 8-bit 양자화의 bit truncation·saturation (명세 규칙)], w: 80%)

== Winograd Convolution — 일반 이론 <sec-winograd-theory>

Winograd minimal filtering은 컨볼루션을 *다항식 곱셈* 으로 보는 데서 출발한다. 길이 $r$의
커널과 길이 $n$의 입력 신호를 각각 다항식 $g(x)$, $d(x)$로 보면, 1D 컨볼루션의 출력은
곱 다항식 $s(x) = g(x) dot d(x)$의 계수와 정확히 같다. $g$가 $r-1$차, $d$가 $n-1$차이므로
$s$는 $(n+r-2)$차, 즉 계수가 $n+r-1$개다.

차수 $D$의 다항식은 서로 다른 $D+1$개의 점에서의 값으로 유일하게 결정된다(보간 정리).
따라서 $s(x)$의 $n+r-1$개 계수를 얻으려면, 다항식을 직접 전개(직접 컨볼루션 = $n dot r$회
곱셈)하는 대신 *서로 다른 $n+r-1$개 점 $alpha_i$ 에서 $g(alpha_i) dot d(alpha_i)$ 를 곱한 뒤
라그랑주 보간으로 계수를 복원* 하면 된다. 이때 곱셈은 점마다 한 번씩, 총 $n+r-1$회만
일어난다. 점에서의 평가($g(alpha_i)$, $d(alpha_i)$)와 보간(복원)은 모두 입력·커널의 선형
결합이므로 *상수 행렬과의 곱(덧셈·시프트)* 으로 처리된다 — 곱셈기 비용을 가산기로 옮기는
것이 Winograd의 핵심이다. 이것이 일반적으로 $F(m, r)$ ($m = n - r + 1$ 출력)을 $m dot r$
대신 $m + r - 1$회 곱셈으로 계산하는 Toom-Cook 알고리즘이다.

여기에 한 가지 절약이 더 있다. 보간점 중 하나로 *무한대 점($infinity$)* 을 도입하면(최고차
계수를 직접 취하는 것에 대응) 유한 점을 하나 덜 써도 되고, 모듈러 산술로 보면 필요한 점
수를 $n+r-1$보다 줄일 수 있다(Toom-Cook). 본 프로젝트가 쓰는 점 집합에도 $infinity$가
포함된다.

행렬 형태로 쓰면 2D 변환은 다음과 같다.

$ Y = A^T [ (G g G^T) circle.stroked.small (B^T d B) ] A $

$g$는 커널, $d$는 입력 타일이며, $G$(weight 평가)·$B^T$(input 평가)·$A^T$(보간/복원)는
선택한 보간점들로부터 유도되는 상수 행렬이다. 곱셈은 element-wise 곱($circle.stroked.small$)에서만
발생한다. 예로 1D $F(2,3)$은 점 $\{0, 1, -1, infinity\}$를 써서 직접 6회 대신 *4회* 곱셈으로
두 출력을 낸다. 2D $F(m times m, 3 times 3)$은 직접 $m^2 dot 9$ 대신 $(m+2)^2$회 곱셈을
쓰므로, $m$을 키울수록 절감이 커진다 — $F(2,3)$은 $9 -> 4$($2.25 times$), $F(4,3)$은
$36 -> 16$ per output로 $144 -> 36$($4 times$).

*그러나 표준 실수 보간점으로 $m$을 키우면 변환 행렬에 점점 복잡한 분수가 나타난다.* 예컨대
$F(4,3)$의 $G$에는 $1\/24$ 같은 원소가 들어간다. 이 분수는 INT8 정수 격자와 어긋나 양자화
정밀도를 떨어뜨리고, 분모를 흡수하기 위한 추가 시프트·자릿수가 DSP·자원 예산을 더 소비한다.
이 두 문제가 @sec-winograd-decision 에서 복소수 보간점으로 확장하는 동기가 된다.
