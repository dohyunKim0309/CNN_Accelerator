#import "../helpers.typ": *

= Problem Definition & Solution <sec-problem>

== 문제 정의

본 프로젝트의 목표는 MNIST 10,000장을 Arty A7-100T 위에서 분류하되 *end-to-end
latency를 최소화* 하는 것이다. 제약은 정확도 무손실(제공된 INT8 파라미터를 비트-정확하게
재현)과 보드 자원 한도(DSP 240, BRAM 135, LUT 63K, FF 126K)다. 평가 우선순위는
latency > power > 자원이며, 모든 설계 선택은 논리적으로 정당화되어야 한다. 이하의
결정들은 이 목표·제약에서 차례로 도출된다.

== Conv2를 최적화 1순위로 — MAC의 90.2% 집중 <sec-conv2-priority>

먼저 어디에 노력을 집중할지를 정해야 한다. @sec-linebuffer 앞의 MAC 분포를 보면
곱셈 연산은 Conv1 48,672회(6.6%), *Conv2 663,552회(90.2%)*, FC 23,040회(3.1%)로,
Conv2가 전체의 90% 이상을 차지한다. 따라서 자원 배분과 알고리즘 최적화(후술하는
Winograd)는 모두 Conv2에 집중한다. FC나 Conv1을 먼저 최적화하는 안은 전체 latency
기여가 작아 투자 대비 효과가 낮으므로 택하지 않았다.

== DSP48E1 SIMD packing — 1 DSP에 INT8 곱 2개 <sec-packing>

DSP 분배(@sec-dsp-alloc)는 1개의 DSP가 곱셈을 1개 하느냐 2개 하느냐에 따라 기준 자체가
달라지므로, packing을 먼저 정한다.

Artix-7의 DSP48E1은 25×18 signed multiplier다. INT8 곱을 1개씩만 수행하면 25비트 A
포트가 낭비된다. 대신 두 weight $W_0, W_1$과 공유 activation $X$를 다음과 같이 한 곱에 싣는다.

$ A = W_1 dot 2^17 + W_0 quad (25"-bit"), quad B = X quad (18"-bit") $
$ A dot B = (W_1 dot X) dot 2^17 + (W_0 dot X) $

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/dsp48e1_structure.png",
    [그림 F7: DSP48E1 구조 (A 25b / B 18b / 25×18 mult / P 48b)], w: 100%),
  figbox("figures/existing/simd_packing_bitmap.png",
    [그림 F8: SIMD packing 비트맵 (W0 하위 17b, guard, W1 상위)], w: 100%),
)

그림 F8이 보여주듯, $W_0 dot X$는 하위 17비트(guard bits 포함)에, $W_1 dot X$는 그 위에
자리하여 둘이 겹치지 않는다. 따라서 한 번의 DSP 연산에서 다음과 같이 분리 추출한다.

```
P0 = W0·X = sint17(P mod 2^17)
P1 = W1·X = sint16( floor(P / 2^17) mod 2^16 ) + [P0 < 0] - 256·X·ovf
            ( ovf = [W1 = -128 and W0 < 0] )
```

이론상 $W_1 = -128$ 이고 $W_0 < 0$일 때 25비트 표현이 overflow하므로 산술 보정항
$-256 dot X dot "ovf"$와 carry 보정 $[P_0<0]$을 두어 bit-exact를 보장한다. 다만 *본 과제의
실제 제공 가중치에는 -128이 없다.* Python으로 세 레이어 weight 범위를 전수 확인한
결과 Conv1 $[-127, 123]$, Conv2 $[-127, 127]$, FC $[-127, 118]$로 *-128 개수가 모두 0*
이며, "SIMD packing overflow condition does NOT occur"임을 검증했다.

#figbox("figures/existing/weight_no128_check.png",
  [그림 F9: weight -128 부재 검증 — 레이어별 min/max, -128 cnt=0, "No Overflow"], w: 75%)

따라서 이 보정 경로는 본 과제에서 실제로 동작하지 않으며, 그 가치는 실측 성능이
아니라 임의 INT8 가중치에 대한 일반성에 있다(자세한 위치 설정은 @sec-disc-packing).

여기서 한 가지 결정이 더 따라온다: *무엇을 패킹할 것인가.* Weight에는 -128이 없지만,
*Conv1 출력 activation에는 -128이 있을 수 있다.* 만약 activation을 패킹한다면 -128
처리용 추가 로직이 PE마다 필요해 비용이 커진다. 따라서 weight 두 개($W_0, W_1$)를
패킹하는 것이 최선이다. 그 귀결로, 한 DSP 묶음에서 나오는 두 결과가 *서로 다른 출력
채널(OC) 두 개* 가 되도록 강제된다(OC 방향 packing). 이 사실은 @sec-dsp-alloc 에서
"왜 IC가 아니라 OC를 2× 방향으로 펼치는지"의 직접 근거가 된다.

이 기법으로 DSP당 throughput이 2배가 된다 — 같은 DSP 예산으로 두 배의 곱셈을 수행한다.
선행연구 대비 차별점은, Xilinx WP486은 DSP48E2(27비트 A 포트) 전용이고 Vestias(FPL'17)는
-128에서 손상이 발생하는 반면, 본 기법은 *DSP48E1(25비트)에서 산술 보정만으로 전 INT8
케이스를 무손상 처리* 한다는 점이다(전수 검증은 @sec-results).

== DSP 분배 <sec-dsp-alloc>

각 레이어에 DSP를 몇 개 줄 것인가는 곱셈 수에서 출발한다. 각 레이어의 연산을 중첩 루프로
정의하고, 곱셈 수를 세고, 곱셈 수에 비례해 240개를 나눈 _이상적_ (비정수) 값을 구한 뒤,
정수 제약·약수 제약·packing 방향(@sec-packing)·구조 단순성을 차례로 적용해 실제 정수
분배로 좁힌다.

=== 각 레이어의 연산 정의

각 conv 레이어가 어떤 곱셈을 몇 번 하는지를 중첩 루프로 정의한다. 이 루프의 *각
차원(KH, KW, IC, OC, OH, OW)이 곧 병렬화 후보 축* 이며, 어떤 축을 병렬화하든 그
병렬도는 해당 차원의 *약수* 여야 한다(나누어떨어지지 않으면 잔여 처리 로직이 붙는다).
Conv2를 대표로 보이면 다음과 같다.

```python
# Conv2: IC=8, OC=16, KH=KW=3, OH=OW=24
for oh in 0..23:
  for ow in 0..23:
    for oc in 0..15:
      acc = 0
      for ic in 0..7:
        for kh in 0..2:
          for kw in 0..2:
            acc += act[ic][oh+kh][ow+kw] * w[oc][ic][kh][kw]
      out[oc][oh][ow] = truncate_relu(acc)   # >>10, saturate, ReLU
```

Conv1(IC=1, OC=8, K=3×3, OH=OW=26)과 FC(2,304→10의 행렬-벡터곱)도 같은 형식의
의사코드로 제시한다.

=== 곱셈 수와 이상적 DSP 비례 분배

위 루프로부터 곱셈 수가 정해진다: Conv1 48,672, Conv2 663,552, FC 23,040, 총
735,264회다. 모든 레이어가 같은 시간에 처리를 마쳐 파이프라인이 균형을 이루려면,
*곱셈 수에 비례해 DSP를 나누는 것* 이 이상적이다(packing의 2배 throughput은 모든
레이어에 공통이므로 비율에는 영향을 주지 않는다). DSP 240개를 모두 쓴다고 가정하면
레이어별 이상적 DSP 값은 다음과 같다.

#figure(
  table(
    columns: 5, align: (left, right, right, right, right),
    table.header[레이어][곱셈 수][비율][이상적 DSP][실제 분배],
    [Conv1], [48,672], [6.6%], [15.9], [18 (→ Wino 36)],
    [Conv2], [663,552], [90.2%], [216.6], [192],
    [FC], [23,040], [3.1%], [7.5], [16],
  ),
  caption: [표 T8: 곱셈 수 → 비율 → 이상적 DSP → 실제 분배],
)

FC는 약수·병렬화 구조상 16 DSP로 구현되어 이상값 7.5보다 크다. baseline 총합은
$192+18+16 = 226$/240 (94%)이다. 문제는 이상값이 정수가 아니라는 점이다. 실제로는
(a) DSP가 정수여야 하고, (b) 병렬도가 각 축의 약수여야 하며, (c) packing이 OC 방향
2×를 강제하고(@sec-packing), (d) 누적·제어 구조가 단순할수록 좋다. 이 제약들을 Conv2에
적용한 결과가 다음 항이다.

=== Conv2: 144 기각, 192 확정 <sec-conv2-alloc>

본 보고서의 *축 명명은 RTL(`conv2_engine.v`)을 따른다.*

- *언롤(공간 병렬) = K_row(커널 행, KH=3)* — `pe_x[K_row][IC]`로 인덱싱, PE array는
  $192 = "OCpair"8 times "IC"8 times "Krow"3$.
- *시퀀셜 누적 = K_col(커널 열, KW=3)* — `fsm_col_sel`이 한 열씩 선택하고
  `kcol_accumulator`가 3사이클에 걸쳐 누적.

즉 *커널 행은 공간적으로 펼치고(병렬), 커널 열은 3사이클에 걸쳐 시분할 누적* 한다.

직접 Conv2의 한 출력 픽셀은 $"IC"8 times "KH"3 times "KW"3 = 72$ MAC을 요구하고, 전체는
$72 times "OC"16 times "OH"24 times "OW"24 = 663,552$회다. 한 사이클에 처리할 곱셈 수의 두
후보는 다음과 같다.

```
144 = IC8 × K9 × SIMD2          (IC 전체 × 커널 9탭 전부 언롤 × packing 2)
192 = OC_pair8 × IC8 × K_row3   (OC16 packing 2 × IC 전체 × 커널 '행'만 언롤)
```

*144를 기각한 이유* 는 이상값에 있다. Conv2의 이상적 몫은 216.6 DSP인데, 144만 쓰면
약 70여 개의 DSP가 남는다. 남은 자원만큼 사이클이 길어져 파이프라인 균형이 깨지므로,
한 축의 병렬도를 키워 240 예산에 더 가깝게 채워야 한다.

*확정한 분배는 192 DSP* ($= "OCpair"8 times "IC"8 times "Krow"3$, Conv2 몫)이다. 이는
Conv2의 이상값 216.6에 144보다 훨씬 가까우면서(Conv1 18·FC 16과 합치면 전체 226/240,
94%를 채운다) 동시에 packing이 쉽고 누적 구조가 단순한 방향이다. 세 가지 세부 결정이
여기에 얽혀 있다.

첫째, *왜 OC 방향 2×인가(IC 패킹이 아니라).* @sec-packing 에서 본 대로 한 DSP 묶음의
두 결과는 서로 다른 OC가 되도록 _weight_ 를 패킹해야 한다. IC를 패킹 축으로 쓰려면
_activation_ 을 패킹해야 하는데, Conv1 출력 activation에는 -128이 있을 수 있어 PE마다
보정 로직이 붙는다. 따라서 OC를 packing 축으로 택했다.

둘째, *왜 커널 열(K_col)을 펼치지 않고 3사이클 누적하는가.* 한 윈도우의 3×3 = 9탭은
`window_register`에 9개가 모두 동시 가용하므로, 원리상 9탭을 전부 펼치는 것도 가능하다(이는
곧 144 경로다). 그러나 9탭 전부 언롤은 240 예산을 다 쓰지 못하고, 반대로 OC·IC를 더
펼치면 예산을 초과한다. 240 안에서의 균형점이 바로 "커널 행 3개만 공간 언롤 + 커널 열
3개는 3사이클 시퀀셜 누적"이다. 이 경우 누적 경로가 `krow_ic_adder_tree`(행·IC 합) →
`kcol_accumulator`(열 3사이클 합)로 단순하게 떨어진다. 이때 한 이미지의 _순수 연산_
사이클은 $"OH"24 times "OW"24 times "KW"3 = 1,728$이고, 여기에 파이프라인 fill/drain
오버헤드가 더해져 실제 throughput floor는 *약 1,799 cyc/img* 가 된다(@sec-optim 에서 이
값을 latency 추정에 사용).

셋째, *왜 IC나 OC를 더 잘게 쪼개지 않는가.* OC나 IC를 부분 그룹으로 더 나누면 부분합을
따로 보관했다가 나중에 더하거나 time-multiplexing해야 하므로 누적·스케줄 FSM이 복잡해진다.
IC=8 전체를 한 번에 펼치면 cross-IC 합이 하나의 가산 트리로 끝나 제어가 간단하다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[병렬화 옵션][DSP][기각/채택 사유],
    [144 = 9탭 전부 언롤], [144], [기각 — 예산 미달(~70 DSP 남음)],
    [IC를 패킹 축으로], [—], [기각 — activation(-128) 패킹 추가로직],
    [OC·IC 추가 분할], [>240], [기각 — 예산 초과 + 부분합 FSM 복잡],
    [커널 열도 언롤], [—], [기각 — 9탭 언롤=144 경로와 동일],
    [행 언롤 + 열 3-cyc 누적], [192], [채택 — 예산 근접·단순 누적],
  ),
  caption: [표 T9: 병렬화 옵션 vs DSP 예산·packing·누적 단순성],
)

#block(inset: (left: 8pt), stroke: (left: 2pt + luma(180)))[
  주: @sec-linebuffer 의 line-buffer 비대칭은 _윈도우를 만드는 단계_ (여러 output row를
  동시 생성 시 line buffer 복제 비용)에 대한 것이지, 이미 만들어진 윈도우 _내부_ 의 9탭
  선택과는 무관하다. 윈도우 내부 축(K_row/K_col) 선택의 근거는 위의 DSP 예산
  트레이드오프이고, @sec-linebuffer 는 OH(출력 행) 병렬화를 쓰지 않은 이유로만 인용한다.
]

== Inter-image pipelining과 분산 FSM 제어 <sec-pipeline>

1만 장을 _연속_ 으로 추론할 때는 단일 이미지 latency보다 stage 간 overlap이 throughput을
좌우한다. 따라서 stage 사이를 ping-pong BRAM 버퍼로 분리하여, 한 engine이 다음 이미지를
쓰는 동안 다음 engine이 이전 이미지를 읽도록 했다. 제어는 중앙 컨트롤러를 두지 않고,
각 engine이 자체 FSM과 bank-toggle FF를 가지며 stage 간 `write_done`/`read_done`(각
1-cycle pulse) 핸드셰이크로만 동기한다.

중앙 컨트롤러(단일 거대 FSM) 방식은 제어 신호가 모든 engine으로 fanout되어 fanout·timing
closure에 불리하고, 특히 오버클럭 시 병목이 된다(실제로 @sec-optim 의 closure에서
high-fanout 제어 net이 반복적으로 문제였다). 분산 제어는 이 부담을 구조적으로 회피한다 —
이 이점의 정량 평가는 @sec-disc-insight 에 둔다.

== AXI burst를 위한 32-bit 비대칭 BRAM 설계 <sec-bram>

PS→PL 데이터 전송은 전체 latency에서 큰 비중을 차지한다(실측에서 CDMA feed가 72%,
@sec-disc-limit). 따라서 data-path BRAM을 *Port A는 32-bit(PS write, AXI burst 친화),
Port B는 엔진 소비 폭(8\~128-bit)* 의 비대칭 구성으로 설계하여, PS 측은 32-bit
word·burst로 전송 효율을 높이고 엔진 측은 필요한 폭으로 병렬 read하게 했다.

대안으로 대칭 8-bit 포트는 전송이 비효율적이고, .coe로 BRAM을 초기화하는 방식은 명세가
금지할 뿐 아니라 PS 전송 시간을 측정에서 누락시키므로 모두 기각했다. 모든 weight·image는
PS가 AXI로 write한다.

== 멀티클럭 사전 설계 (PS 100MHz / PL datapath + CDC) <sec-multiclock>

오버클럭은 PL datapath에서만 의미가 있다. 처음부터 단일 클럭으로 설계하면 클럭을 올릴
때 PS·AXI까지 끌려 올라가 closure가 불가능하다. 따라서 PS(100MHz)와 PL datapath 클럭을
처음부터 분리하고, 경계에 CDC(`cdc_pulse_sync`/`cdc_bit_sync`)를 미리 깔아 두어 후일 PL만
150/200MHz로 올릴 여지를 확보했다. 이 사전 분리가 @sec-optim 오버클럭 로드맵 전체의
전제다(구현·동작은 @sec-impl-base). 단일 클럭 도메인 안은 오버클럭 확장성이 없고 나중에
재설계 비용을 치르게 되므로 택하지 않았다.

== Complex Winograd F(4×4, 3×3) 도입 <sec-winograd-decision>

Conv2가 곱셈의 90%를 차지하므로, 곱셈 수 자체를 줄이는 것이 가장 효과적이다. @sec-winograd-theory
에서 보았듯 $F(m,3)$의 출력당 곱셈은 $9 -> (m+2)^2\/m^2$로 줄고, $m$이 클수록 절감이 크다.
따라서 _원리상 가장 좋은 선택은 $m$을 키우는 것_ 이다.

그러나 표준 실수 보간점으로 $m$을 키우면 두 문제가 동시에 악화된다. 변환 행렬 원소는
라그랑주 보간 계수이고, 그 분모에는 *보간점들 사이의 거리 곱* 이 나타난다 — 점이 많아지고
서로 멀어질수록 분모가 큰 합성수가 되어 행렬에 복잡한 분수가 생긴다. 그 결과 (1) 분수가
INT8 정수 격자와 어긋나 양자화 정밀도가 추가로 떨어지고(baseline이 이미 93% 수준이라 여유가
적다), (2) 분모를 흡수하기 위한 자릿수 확장이 DSP·자원 예산을 더 소비한다.

핵심 관찰은 *분모가 보간점들 사이 거리의 곱이라면, 점들을 서로 가깝게 두면 분수를 통제할 수
있다* 는 것이다. 점을 실수축에만 두면(예: $0, plus.minus 1, plus.minus 2, dots$) 점이 늘수록
점 사이 거리가 커질 수밖에 없지만, *복소 평면으로 확장* 하면 작은 거리를 유지한 채 점을 더
모을 수 있다. 유한점 $\{0, plus.minus 1, plus.minus i\}$를 보면 서로 간 거리가 $1, sqrt(2), 2$
세 값뿐이어서 분모가 작은 정수로 유지된다. 여기에 무한대 점 $oo$를 더한 $\{0, plus.minus 1,
plus.minus i, oo\}$가 이렇게 거리를 통제하며 모을 수 있는 *최대 집합(6개)* 이고, 이 6점으로
만들 수 있는 변환은 *$F(4,3)$이 한계* 다($m + 2 = 6$). $F(5,3)$은 점이 7개 필요한데 거리를
작게 유지하며 7번째 점을 추가할 수 없어 사실상 불가능하다 — 가능했다면 더 키웠을 것이다. 이
6점을 택하면 $G, B^T, A^T$가 모두 Gaussian integer($\{0, plus.minus 1, plus.minus i,
plus.minus 4\}$)가 되어 *분수가 전혀 없고*, $1\/16$ 스케일만 출력 시프트로 흡수된다.

#grid(columns: (1fr, 1fr), gutter: 8pt,
  figbox("figures/existing/winograd_f43_transform.png",
    [그림 F5a: 표준(실수) F(4,3) 변환행렬 — ±1/24 분수 포함], w: 100%),
  figbox("figures/existing/complex_winograd_f43_transform.png",
    [그림 F5b: complex F(4×4,3×3) 변환행렬 — 전부 Gaussian integer], w: 100%),
)

복소 확장은 곱셈 수에 손해도 준다. 복소 곱은 본래 실수 곱 4회지만, 실수 입력의 켤레 대칭
$s(-i) = overline(s(i))$로 켤레 점의 절반이 공짜로 얻어지고, 남은 복소 곱은 Gauss
트릭($k_1=a(c+d), k_2=c(b-a), k_3=d(a+b)$)으로 1회를 실수 곱 3회로 줄인다.

#figbox("figures/existing/gauss_mul.png",
  [그림 F5c: Gauss 트릭 — 복소 곱 1회를 실수 곱 3회로], w: 55%)

그 결과 한 타일당 곱셈은 (real,real) 16 + (real,cplx) 4×3 + (cplx,real) 4×3 +
(cplx,cplx) 2×3 = *46회* 가 된다. 전체로는 직접 conv의 663,552회가 211,968회로 *3.13× 감소*
한다 — 실수 $F(4,3)$의 36회(4×)보다는 많지만, 그 4×는 INT8에서 정밀도·예산 손실을 동반하므로
취할 수 없다. *bit-exact를 유지하면서 얻을 수 있는 최대 절감이 complex $F(4,3)$의 3.13×* 이며,
이것이 본 과제의 정확도 무손실 제약 아래 최선이다.

== Conv1 2× rebalance <sec-conv1-2x-decision>

Conv2를 Winograd로 빠르게 만들면 병목이 Conv1로 이동한다. 따라서 Conv1을 DSP 18→36으로
늘리고 2-round를 1-round로 바꿔 약 837 cyc로 재균형했다. Conv1을 방치하면 Winograd의
3.13× 이득이 Conv1에 가려져 무의미해지므로, rebalance는 선택이 아니라 필수다. 병목 이동의
정량 분석은 @sec-disc-insight 에 있다.
