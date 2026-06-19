#import "../helpers.typ": *

= Discussion <sec-discussion>

== DSP48E1 SIMD packing의 재평가 — 특히 -128 보정 <sec-disc-packing>

SIMD packing은 본 설계에서 가장 효과가 컸던 결정이다. 한 DSP가 두 INT8 곱을 처리하므로
같은 240개 예산으로 사실상 두 배의 연산을 얻었고, 이는 Conv2를 192 DSP로 닫을 수 있게 한
직접적 전제였다.

-128 corner case 보정은 과대평가하지 않도록 위치를 분명히 둔다. 이론상 $W_1=-128$ 이고
$W_0<0$일 때 25비트 표현이 overflow하므로 산술 보정항을 설계에 포함했으나, *본 과제의
실제 제공 가중치에는 -128이 존재하지 않아 이 보정 경로는 실측에서 한 번도 활성화되지
않았다* (@sec-packing 그림 F9의 전수 검증: 세 레이어 모두 -128 cnt=0). 따라서 이 보정을
"실측 성능 기여"로 과대평가해서는 안 된다. 그 가치는 두 가지 다른 측면에 있다. 첫째는
일반성이다 — 임의의 INT8 가중치(재학습된 다른 모델 포함)에 대해서도 bit-exact를 보장하므로,
이 PE는 본 과제에 한정되지 않는 재사용 가능한 빌딩 블록이다. 둘째는 선행연구 대비 위치다 —
Xilinx WP486은 27비트 A 포트를 가진 DSP48E2 전용이고 Vestias(FPL'17)는 -128에서 손상이
발생하는데, 본 기법은 더 좁은 DSP48E1(25비트)에서 산술 보정만으로 전 케이스를 무손상
처리한다. 2²⁴ exhaustive 검증(@sec-results)이 이 일반성을 뒷받침한다. 실제 데이터엔 -128이
없었음을 명시하는 것이 오히려 주장의 신뢰도를 높인다.

== 디버깅 사례 1 — AXI-Lite write hang <sec-disc-debug>

CSR read는 정상인데 첫 CSR write에서 MicroBlaze가 무한 hang하는 문제가 있었다. 원인은
Xilinx "Create AXI4 Peripheral → Lite" 템플릿의 핸드셰이크 버그였다 — write address(AW)와
write data(W)가 도착하는 순서를 slave FSM이 암묵적으로 가정하고 있어서, W가 AW보다 먼저
오는 경우(AXI 규약상 합법) FSM이 멈춰 BVALID를 발행하지 못했다. 해결은 `AWVALID && WVALID`가
동시에 성립할 때만 ready를 assert하도록 핸드셰이크를 고친 것이다(코드 C9는 부록).

이 사례의 일반적 교훈은 *AXI interconnect는 W를 AW보다 먼저 보낼 수 있으며, slave는 채널
도착 순서를 가정해서는 안 된다* 는 것이다. 벤더 템플릿이라고 해서 모든 합법 시나리오를
처리한다고 믿을 수 없다는 점도 함께 확인했다.

== 디버깅 사례 2 — NBA register race

이 버그는 발현 양상 자체가 교훈적이었다. 단위 테스트(maxpool 단독 40장)는 통과하는데 통합
테스트(conv1→conv2→maxpool 40장)에서만 img 1부터 거의 모든 픽셀(\~115/144)이 틀렸다. 원인을
추적하니 maxpool의 image 1 write_done이 conv2의 image 1 write_done보다 82 cycle 빨랐다 —
즉 maxpool이 conv2가 아직 c2pool 버퍼에 쓰지 않은 영역을 읽고 있었다.

근본 원인은 NBA(non-blocking assignment) 타이밍이었다. maxpool FSM이 핸드셰이크 카운터
`prior_diff`를 같은 사이클에 갱신(NBA)하면서, 동시에 그 값을 조합 조건 `data_ready =
(prior_diff < 0)`으로 FSM 전이에 썼다. NBA는 사이클 끝에 갱신되므로 조건은 _이전 사이클의
값_ 을 보게 되고, 그 결과 한 박자 이른 잘못된 전이가 일어났다. 단위 테스트가 이를 놓친
이유는, 단독 TB가 입력 pulse를 인위적으로 벌려 주어 race window가 생기지 않았기 때문이다 —
engine 간 자연스러운 타이밍에서만 드러나는 결함이었다. 해결은 현재 사이클의 trigger를 반영한
조합값 `prior_diff_next`로 조건을 판정한 것이다(코드 C10은 부록).

일반적 교훈은 *counter 기반 조건으로 전이를 결정하는 FSM은, 그 counter가 같은 사이클에
갱신될 때 반드시 `*_next` 조합값을 써야 한다* 는 것이다. 또한 이 사례는 단위 테스트만으로는
engine 간 상호작용 결함을 못 잡으므로 통합 테스트가 필수임을 보여준다.

#block(inset: (left: 8pt), stroke: (left: 2pt + luma(180)))[
  주: Direct/Winograd의 오버클럭 단계별 진단 서사(BMG register, fanout, silent timing failure,
  reset tree, phys_opt 등)는 @sec-optim 에 있다. 그 과정에서 얻은 일반 교훈(high-fanout net의
  route delay가 벽이며 `max_fanout` 복제가 처방, positive WNS @ slow corner만 신뢰)도 거기에 정리했다.
]

== Power 분석 (명세 우선순위 \#2) <sec-disc-power>

명세는 latency 다음으로 power를 중시하고(p.6), power 리포트 setup을 default에서 바꾸지 말라고
못박는다(p.7). 따라서 power를 단순 수치(@sec-results)로 끝내지 않고 트레이드오프 관점에서
해석한다.

먼저 오버클럭과 power의 관계다. 클럭을 150에서 200 MHz로 올리면 dynamic power는 switching
빈도에 비례해 증가한다. 그러나 명세 \#2의 기준은 "throughput을 손해 보지 않는 선에서 최소
power"이므로, latency가 실제로 줄어드는 한 클럭 상승은 \#2 위반이 아니라 \#1(latency 최우선)과
정합한다. 더 의미 있는 지표는 *단위 추론당 에너지(energy per inference = power × latency)* 다 —
클럭을 올려 latency가 짧아지면 전력이 다소 늘어도 추론 한 건당 에너지는 오히려 줄어들 수 있다.

다음은 Baseline과 Winograd의 power 비교다. Winograd는 DSP 점유가 더 높고(94%→98%) transform
network 때문에 LUT가 늘어 정적/동적 power 구성이 다르다. 핵심 질문은 곱셈 수 3.13× 감소(곱셈을
가산으로 치환)가 연산 에너지를 실제로 줄이는지, 아니면 transform 오버헤드가 그 이득을
상쇄하는지다. 이는 측정값으로 평가해야 하며, Winograd는 보드 실측이 없어 implementation power
summary만 제시한다(@sec-optim-wino 그림). 모든 수치는 default setup 측정임을 명시해 신뢰성을
담보한다.

== 설계 통찰 — 병목의 이동과 분산 제어 <sec-disc-insight>

이 프로젝트에서 반복적으로 확인된 것은 *지엽적 최적화가 전역 병목을 이동시킨다* 는 점이다. 직접 conv
단계에서는 Conv2(약 1,799 cyc)가 병목이고 Conv1은 1,634 cyc였다. Conv2를 Winograd로 약
1,341 cyc까지 줄이자 이번에는 *Conv1(1,634 cyc)이 새 병목* 이 되었다 — Conv2만 빠르게 해서는
전체 throughput이 1,634에 묶인다. 그래서 Conv1을 2× rebalance해 837 cyc로 낮췄고, 그 결과
병목은 다시 Winograd-Conv2(약 1,341 cyc)로 돌아가 파이프라인 floor가 1,634에서 약 1,341로
내려갔다. 즉 두 레이어가 정확히 같아지는 것이 목표가 아니라, _더 느린 쪽을 더 빠른 쪽 아래로
끌어내려_ 전역 floor를 낮추는 것이 핵심이다.

#figure(
  table(
    columns: 4, align: (left, right, right, right),
    table.header[단계][Conv1 cyc][Conv2 cyc][전역 floor],
    [직접 conv (baseline)], [1,634], [\~1,799], [\~1,799],
    [Winograd만 적용], [1,634], [\~1,341], [1,634],
    [+ Conv1 2× rebalance], [837], [\~1,341], [\~1,341],
  ),
  caption: [표 T3: 병목 이동 — 각 단계의 Conv1·Conv2 cyc와 전역 floor],
)

또 하나는 분산 FSM 제어의 이점이다. 중앙 컨트롤러 대신 각 engine이 자체 FSM과 핸드셰이크로
동기하는 구조(@sec-fsm-impl)는, 제어 신호의 거대 fanout과 그로 인한 timing 부담을 구조적으로
회피한다. @sec-optim 의 timing closure에서 반복적으로 문제가 된 것이 high-fanout 제어 net이었음을
떠올리면, 애초에 중앙 컨트롤러를 피한 결정이 closure를 비교적 수월하게 만든 한 요인이었다고
평가할 수 있다.

== 한계와 Future Work <sec-disc-limit>

가장 중요한 한계는 *병목이 연산에서 데이터 전송으로 이동했다* 는 점이다. 클럭을 100에서 200
MHz로 올렸지만 latency는 2배가 아니라 1.72×만 줄었다. 실측 프로파일상 전체 시간의 72%가 100
MHz 도메인의 blocking CDMA 입력 feed에 쓰이기 때문이다(@sec-results). 가속기 클럭을 올려도
compute slice만 압축될 뿐 feed 시간은 그대로이므로, 설계가 compute-bound에서 memory/feed-bound로
전이한 것이다. 따라서 다음 개선 대상은 연산이 아니라 *feed overlap* (non-blocking/prefetch CDMA +
입력 bank 2개 초과)이다. 이것이 선행되어야 Winograd의 연산 감소가 비로소 end-to-end latency로
환원된다.

둘째, Winograd는 200 MHz를 닫지 못하고 171.42 MHz로 fallback했으며, 무엇보다 *보드 실측을
수행하지 못했다* — 보드 제출 마감 시점의 시간 제약 때문이다. 따라서 Winograd의 성능은
시뮬레이션 bit-exact + 171.42 MHz timing-met + cycle 추정(\~78 ms)으로만 보고되며, 보드
bring-up과 200 MHz closure(@sec-optim-wino 의 처방 — route-bound은 over-constrain,
logic-bound reduce는 파이프라인 분할 — 를 결합)가 명확한 후속 작업이다.

셋째, @sec-disc-packing 에서 보았듯 -128 보정의 가치는 실측 성능이 아니라 일반성 측면에서만
유효하다 — 다른 가중치로 재학습하는 경우에 의미를 갖는다.
