#import "../helpers.typ": *

= Implementation — Winograd (제안 알고리즘) <sec-impl-wino>

@sec-winograd-decision (Complex Winograd 도입)·@sec-conv1-2x-decision (Conv1 2×)의 RTL
구현이다. RTL은 시뮬레이션 bit-exact로 검증되었고, implementation은 171.42 MHz로
timing-met(200 MHz는 미달), 보드 실측은 시간 제약으로 수행하지 못했다.

== Complex F(4×4,3×3) 데이터패스 구현

=== Winograd 엔진 RTL 구조 <sec-wino-engine>

Conv2 Winograd 엔진(`conv2_winograd_engine.v`)은 입력 (8,26,26) INT8을 6×6 타일 단위로
받아 (16,24,24) INT8을 내는, 직접 conv2와 동일한 외부 인터페이스의 drop-in 모듈이다.
내부는 네 단계의 데이터패스로 구성된다.

*입력 변환* (`wino_input_transform`). $V = B^T dot d dot B$를 계산한다. 변환 계수가
${0, plus.minus 1, plus.minus 4}$뿐이라 *곱셈기를 전혀 쓰지 않고* 시프트·덧셈으로만
수행한다. 6×6 타일의 8-bit 입력 원소를 변환해 곱셈에 들어갈 14-bit operand들로 펼치며(이
operand들이 @sec-winograd-decision 의 46개 곱과 1:1 대응), 3-stage 파이프라인이다.

*곱셈 배열* (`wino_mul_array` / `wino_dsp_mul`). element-wise 곱을 수행하는 곱셈기
군집으로, *4개 lane(각 IC 그룹) × 46 곱 = 184 DSP* 를 쓴다. 각 DSP48E1은 12-bit weight ×
14-bit activation → 24-bit 곱의 3-stage 구성이다. weight는 per-PE distributed LUTRAM에
저장한다(`wino_weight_loader`가 PS write를 받아 적재). `wino_lane_reduce`가 46개 곱을 Gauss
트릭에 따라 26개 부분합으로 축약하고, `wino_m_assemble`이 켤레 대칭으로 36개 M 위치로 확장한다.

*출력 변환* (`wino_output_transform`). $Y = A^T dot M dot A$를 계산한다. 계수가
${0, plus.minus 1}$뿐이라 역시 곱셈기 없이 덧셈으로만 수행하며, 4-stage 파이프라인으로
28-bit 출력을 낸다.

*절단* (`wino_truncate`). Winograd 변환의 1/16 스케일과 레이어 양자화 `>>10`을 결합한
`>>>14` 시프트 + saturation + ReLU로 직접 conv2와 동일한 INT8 양자화를 재현한다. (코드
발췌 C7은 부록.)

엔진 latency는 issue로부터 M_valid까지 +11 cycle, tile_out까지 +17 cycle이며(register 단위
분해는 @sec-wino-timing), 한 이미지 처리 사이클은 top-module TB 측정 기준 *평균 1,348 cyc/img*
이다(분해는 @sec-wino-cyc). (`RTL/conv2_winograd/`)

=== 레이어 내부 제어 — 통신 대신 카운터-구동 FSM <sec-wino-fsm>

@sec-fsm-impl 의 분산 FSM은 *레이어 사이* 의 동기 방식이다(`rdone`/`wdone` 핸드셰이크).
그러나 Winograd 엔진 *내부* 에서는 별개의 선택을 한다. 엔진은 row buffer를 채우는 producer,
타일을 연산하는 consumer, 결과를 C2Pool에 쓰는 writer 세 프로세스가 동시에 도는데, 이 셋은
서로 `done` 신호를 주고받지 않는다. 대신 *각 단의 latency가 데이터에 무관하게 결정적* 이라는
점을 이용해, 타이밍을 사이클 단위로 미리 계산해 고정 latency 파이프라인으로 만들고 FSM
전이를 전부 *내부 카운터 비교* 로 유도한다. 핸드셰이크 net은 die 전역으로 퍼지는 제어 net이라
높은 클럭에서 route delay 벽이 되는데(@sec-optim 의 reset·broadcast가 같은 부류), 내부
경로는 그 비결정성이 없으므로 미리 계산한 카운터가 더 안전하고 빠르다.

main FSM은 IDLE → LOAD_WEIGHTS → WAIT_IMG → LOAD_INIT → RUN → DRAIN 6상태다. 첫 start에서
LOAD_WEIGHTS로 한 번 진입해 PS가 써둔 pre-transformed weight를 per-PE RAM으로 적재하고(이후
이미지 루프에서는 재진입하지 않으므로 weight 적재는 이미지 latency에 들어가지 않는다),
이후 이미지마다 WAIT_IMG(레이어 간 핸드셰이크 대기) → LOAD_INIT(첫 타일-행 적재) → RUN(36
타일 연산) → DRAIN(마지막 타일 배수)을 돈다. RUN 중 진행을 결정하는 카운터는
`compute_cnt`(0\~31, 타일 내 issue 사이클), `tile_cnt`(0\~5, 타일-행 내 타일), `trow_cnt`(0\~5,
타일-행)이며, 마지막 타일의 마지막 issue를 `trow_cnt==5 ∧ tile_cnt==5 ∧ compute_cnt==31`
라는 *순수 카운터 비교* 로 검출해 DRAIN으로 전이한다. issue 시퀀스는 `compute_cnt`로부터
$"oc"="compute_cnt"[4:1]$, $"grp"="compute_cnt"[0]$, weight 주소 $="compute_cnt"$로 모두
파생되므로, 한 카운터가 곱셈기 배열·weight read·태그 파이프라인을 동시에 구동한다.

producer 역시 consumer의 카운터를 *읽기만* 한다. 다음에 적재할 타일-행 `pld_trow`가 consumer가
처리 중인 `trow_cnt`보다 최대 한 행 앞설 때까지만 진행하는 부등식($"trow_cnt"+1 >= "pld_trow"$)이
producer를 앞세우는 유일한 조건이며, consumer→producer 방향 신호는 없다. 이 무신호 동기가
성립하는 근거는 단순한 사이클 부등식이다 — consumer가 한 타일-행을 처리하는 데
$6 "타일" times 32 "cyc" = 192$ cyc가 걸리는 반면, producer가 한 타일-행(6 row × 26 col)을
적재하는 데는 156 read뿐이다. $156 < 192$이므로 producer는 *항상* 먼저 끝나고, consumer가
ping-pong row buffer의 set을 교체할 때 다음 타일-행은 이미 준비되어 있다. 따라서 RUN의 타일-행
경계에서 consumer는 producer를 기다릴 필요가 없으며(무조건 진행), 준비 완료 게이트(`set_ready`)는
오직 *최초* LOAD_INIT → RUN 진입에만 쓰인다. 이 36-cycle 여유가 곧 레이어 내부에서 핸드셰이크를
제거할 수 있는 타이밍 마진이다.

두 set의 row buffer를 타일-행 단위로 교대(`set_active="trow_cnt"[0]`)하는 이 ping-pong에는
한 가지 미세 타이밍 보정이 필요하다. C1C2 BRAM은 출력 레지스터를 켠 2-cycle read latency이므로,
타일-행의 마지막 주소를 낸 직후 read enable을 내리면 그 read가 출력까지 전파되지 못해 row
buffer의 마지막 원소가 갱신되지 않는다. 이 미갱신은 타일-행 우측 끝 타일의 한 픽셀에서만
오류로 나타나는데, producer FSM에 PDRAIN(3 cycle, read enable 유지) 상태를 두어 마지막 read가
출력 레지스터를 거쳐 row buffer까지 안착한 뒤에야 `set_ready`를 올림으로써 해소한다. PDRAIN
3 cycle은 BRAM 2-cycle latency에 row buffer write 레지스터 1단을 더한 값이다.

=== 사이클 예산 — 1,348 cyc/img의 구성 <sec-wino-cyc>

한 이미지의 처리 사이클은 위 카운터들의 진행을 그대로 더해 결정된다. steady-state period(연속
이미지에서 `wdone`과 `wdone` 사이 간격)는 네 항의 합이다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[항목][cycle][근거],
    [WAIT\_IMG], [1], [`ready_to_compute` 판정 1 cycle],
    [LOAD\_INIT], [160], [PIDLE entry 1 + PLOAD 156(6 row × 26 col) + PDRAIN 3],
    [compute (RUN)], [1,152], [36 타일 × 32 cyc],
    [마지막 타일 tail (DRAIN)], [35], [마지막 issue 이후 M·출력·write 배수],
    [*steady-state period*], [*1,348*], [위 네 항의 합 (TB 측정과 일치)],
  ),
  caption: [표 T11: Winograd 엔진의 이미지당 사이클 분해 — 카운터 진행을 그대로 합산],
)

여기서 *throughput을 결정하는 것은 issue rate(1 issue/cyc, FSM 고정)이지 파이프라인 깊이가
아니다.* 한 타일의 마지막 issue 직후 다음 타일의 issue가 곧바로 이어지므로(파이프를 비우지
않으므로) 타일당 실효 사이클은 32로 고정이고, 각 타일의 연산 결과가 흘러나오는 배수(drain)는
*다음 타일 연산의 그림자에 겹쳐* period에 추가되지 않는다. 오직 *마지막 타일* — 뒤에 겹칠
타일이 없는 — 의 배수만 RUN 끝에 노출되며, 이것이 표 T11의 tail 35 cycle이다(마지막 issue로부터
M_valid +11, 출력변환·절단·수집 +6, 그리고 16 픽셀 write). 그 결과 오버클럭 과정에서 파이프라인을
깊게 분할해도(입력변환 3-stage, 출력변환 4-stage 등) 이미지당 사이클은 tail에만 영향을 줄 뿐
throughput은 불변이며, 이것이 깊은 파이프라인을 "공짜로" 쓸 수 있는 이유다(@sec-optim-wino).

=== 엔진 타이밍 앵커 — issue에서 출력까지 <sec-wino-timing>

연산의 모든 사이클은 곱셈기 배열의 *issue 사이클* 을 기준점으로 정렬된다. issue된 한 데이텀이
M_valid에 도달하기까지 거치는 레지스터는 정확히 11단이다 — row buffer read 레지스터 1단,
입력변환 2단(3-stage 중 마지막은 조합), 활성 레지스터 1단, DSP 3단(AREG/BREG → MREG → PREG),
lane partial 레지스터 1단, gather 레지스터 2단, M 누적 latch 1단. M_valid 이후로는 출력변환
4단, 절단 1단, 수집 1단을 더 거쳐 issue로부터 tile_out까지 총 17단이다. 한 타일 내에서 OC별
M_valid는 그 OC의 grp1이 issue되는 사이클($c=2"oc"+1$)에 11을 더한 $2"oc"+12$에 정렬된다.

#figure(
  table(
    columns: 3, align: (left, center, left),
    table.header[사건][타일 내 사이클][식],
    [issue (oc, grp)], [$c = 0 dots 31$], [grp1(oc) @ $c=2"oc"+1$],
    [M\_valid(oc)], [$2"oc"+12$], [grp1 issue + 11],
    [출력변환 완료 (Y16)], [$2"oc"+16$], [+ 출력변환 4-stage],
    [절단 출력], [$2"oc"+17$], [+ 절단 1],
    [tile\_out 기록], [$2"oc"+18$], [+ 수집 1],
  ),
  caption: [표 T11b: 한 타일 내 OC별 타이밍 정렬 — oc0은 12/18, oc15는 42/48 사이클에 완성],
)

이 정렬에서 마지막 OC(oc15)의 tile_out 기록(사이클 48)이 곧 타일 완성 신호가 되어 writer를 트리거하고,
M의 좌표(oc·타일 위치)는 issue 시점으로부터 같은 단수만큼 지연된 태그 파이프라인(깊이 15)으로
추적되어 수집 단에서 올바른 `tile_out` 위치에 기록된다. 따라서 M 경로 latency를 한 단이라도
바꾸면 태그 파이프 깊이와 수집 인덱스를 함께 옮겨야 하며, 이는 @sec-optim-wino 의 carry-bisect
시도가 latency를 +1 늘리며 정렬 묶음을 흔든 지점과 정확히 일치한다.

=== Conv1 2× rebalance 구현

@sec-conv1-2x-decision 결정대로 Conv1을 DSP 18→36, 2-round→1-round 구조로 바꿨다. PE
군집을 2그룹×9에서 4그룹×9(36 DSP)로 늘려 사이클당 출력을 4 OC에서 8 OC로 두 배로 하고,
RUN2·FLUSH2·LBRST 상태를 제거해 FSM을 8상태에서 5상태(IDLE/LOAD/RUN/FLUSH/DONE)로
단순화했다. 이로써 한 이미지가 1,634 cyc에서 *837 cyc* 로 줄었다(−797 cyc). 데이터패스
깊이와 FLUSH 길이는 불변이다. (`RTL/conv1_2x/`) 결정·근거는 @sec-conv1-2x-decision, 병목
이동 정량 분석은 @sec-disc-insight 에 있다.

=== SIMD packing의 Winograd 적용

@sec-packing 의 SIMD packing을 Winograd 곱셈 배열에도 적용한다. 전체 DSP 사용량은
Winograd Conv2(184) + Conv1 2×(36) + FC(16) = 합성 결과 *236/240(98.33%)* 로 거의 포화
상태다(@sec-results hierarchical util). weight에 -128이 없으므로 packing이 무손상이고,
Winograd 누적에서도 bit-exact가 보장된다(보정의 일반성 측면 가치는 @sec-disc-packing).

== 오버클럭 이후

Winograd의 timing closure(200 MHz 시도 → 171.42 MHz met)는 @sec-optim-wino 에서 다룬다.
