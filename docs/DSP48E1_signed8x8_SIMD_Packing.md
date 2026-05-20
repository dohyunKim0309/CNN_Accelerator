# DSP48E1 Signed 8×8 SIMD Packing 알고리즘 (Weight Packing)

## 0. 문제 정의

DSP48E1 의 단일 25×18 signed multiplier 로 두 개의 signed 8×8 곱셈을 동시에 수행한다.

**입력**: $W_0, W_1, X \in [-128, 127]$ (모두 signed 8-bit, INT8)
- $W_0, W_1$: 서로 다른 두 weight (예: 두 output channel 의 동일 위치 weight)
- $X$: 공유되는 input activation

**출력**: 
- $P_0 = W_0 \cdot X$
- $P_1 = W_1 \cdot X$

각각 signed 16-bit ($|P_i| \le 128 \cdot 128 = 2^{14}$, 16-bit signed 범위 내).

**제약**: 모든 $2^{24}$ 개 입력 조합에서 정확해야 함 (-128 포함, 양자화 손상 없음).

## 1. Packing 식

DSP48E1 의 multiplier 두 포트:
- A 포트: 25-bit signed
- B 포트: 18-bit signed

다음과 같이 구성:

$$A_{port} = W_1 \cdot 2^{17} + W_0$$
$$B_{port} = X$$

곱셈 결과:

$$P = A_{port} \cdot X = (W_1 X) \cdot 2^{17} + (W_0 X)$$

두 곱이 비트 영역에서 분리되어 동시 계산됨.

## 2. 25-bit 표현 한계와 오버플로우 구역

$A_{port}$ 의 범위:

$$\min A_{port} = (-128) \cdot 2^{17} + (-128) = -16{,}777{,}344$$
$$\max A_{port} = 127 \cdot 2^{17} + 127 = 16{,}646{,}271$$

25-bit signed 범위 $[-2^{24}, 2^{24}-1] = [-16{,}777{,}216, 16{,}777{,}215]$ 와 비교:

| 조건 | $A_{port}$ 상태 |
|:--|:--:|
| $W_1 > -128$ | ✓ 항상 안전 |
| $W_1 = -128, W_0 \ge 0$ | ✓ 안전 |
| $W_1 = -128, W_0 < 0$ | ✗ **오버플로우** (128 케이스) |

## 3. 핵심 통찰: 단일 경로 + 산술 보정

오버플로우 시 DSP 가 보는 실제 값은 $A_{actual} = A_{port} + 2^{25}$ 이므로, 곱셈 결과에 $2^{25} \cdot X$ 만큼의 오차항이 추가된다. 이 오차항을 결과 추출 단에서 산술적으로 보정하면 **분기와 MUX 없이 단일 경로**로 모든 케이스를 정확히 처리할 수 있다.

핵심 관찰:
- **$W_0 \cdot X$ 슬롯 (하위 17비트)**: $2^{25} X$ 는 $2^{17}$ 의 배수이므로 자동 보호.
- **$W_1 \cdot X$ 슬롯 (상위)**: 오차 $2^{25} X / 2^{17} = 256 X$ 가 더해진 형태로 나옴. 오버플로우 검출 시 $-256 X$ 를 합산하여 보정.

## 4. 알고리즘

### 4.1 입력 단계

$$A_{port} = W_1 \cdot 2^{17} + W_0 \quad \text{(25-bit, 정수 산술)}$$
$$B_{port} = X \quad \text{(18-bit signed extension)}$$

### 4.2 오버플로우 검출

$$\text{ovf} = [W_1 = -128 \wedge W_0 < 0]$$

(Pre-packed weight 시나리오: 7.3절 참조)

### 4.3 DSP 곱셈

$$P = A_{port} \cdot B_{port} \quad \text{(43-bit signed)}$$

### 4.4 결과 추출 (단일 경로)

$W_0 \cdot X$ 슬롯:

$$P_0 = W_0 \cdot X = \operatorname{sint}_{17}(P \bmod 2^{17})$$

$W_1 \cdot X$ 슬롯 (단일 식, 분기 없음):

$$P_1 = W_1 \cdot X = \operatorname{sint}_{16}\!\left(\lfloor P / 2^{17}\rfloor \bmod 2^{16}\right) + [P_0 < 0] - 256 X \cdot \text{ovf}$$

- $[P_0 < 0]$: carry 보정 (W_0 X 가 음수일 때 부호확장 비트 보정)
- $-256 X \cdot \text{ovf}$: 오버플로우 시에만 활성화되는 산술 보정

세 항을 **16-bit ternary adder** 하나로 합산.

## 5. 정확성 증명

### 5.1 표기법

정수 $v$ 와 양의 정수 $n$ 에 대해:
- $\operatorname{repr}_n(v) := v \bmod 2^n$
- $\operatorname{sint}_n(u) := u$ if $u < 2^{n-1}$, else $u - 2^n$

$|v| \le 2^{n-1}$ 이면 $\operatorname{sint}_n(\operatorname{repr}_n(v)) = v$.

### 5.2 보조정리

**Lemma 1 (모듈러 곱셈 보존).** $(a \bmod 2^n) \cdot b \equiv a \cdot b \pmod{2^n}$.

**Lemma 2 (DSP 동작).** DSP48E1 의 25×18 signed multiplier 는 $P_{int} = \operatorname{sint}_{25}(A_{bits}) \cdot \operatorname{sint}_{18}(B_{bits})$ 를 계산한다.

### 5.3 정상 케이스 ($\text{ovf} = 0$)

$A_{port}$ 가 25-bit signed 범위 내이므로 $\operatorname{sint}_{25}(\operatorname{repr}_{25}(A_{port})) = A_{port}$. 따라서:

$$P_{int} = (W_1 X) \cdot 2^{17} + (W_0 X) \quad (\star)$$

**Claim A**: $W_0 X = \operatorname{sint}_{17}(P_{int} \bmod 2^{17})$.

*증명.* $(W_1 X) \cdot 2^{17}$ 은 $2^{17}$ 의 배수, $|W_0 X| \le 2^{14} < 2^{16}$ 이므로 17-bit signed 범위 내. $\square$

**Claim B**: $W_1 X = \operatorname{sint}_{16}(\lfloor P_{int}/2^{17}\rfloor \bmod 2^{16}) + [W_0 X < 0]$.

*증명.* $(\star)$ 의 floor division:

$$\lfloor P_{int}/2^{17}\rfloor = W_1 X + \lfloor W_0 X / 2^{17} \rfloor$$

$|W_0 X| < 2^{17}$ 이므로 $\lfloor W_0 X/2^{17}\rfloor = -[W_0 X < 0]$. 따라서 $\lfloor P_{int}/2^{17}\rfloor = W_1 X - [W_0 X < 0]$. 16-bit signed 범위 내이므로 $\operatorname{sint}_{16}$ 적용 후 carry 보정 더하면 $W_1 X$ 복원. $\square$

정상 케이스에서 알고리즘의 보정항 $-256 X \cdot \text{ovf} = 0$ 이므로 $P_1 = W_1 X$. $\square$

### 5.4 오버플로우 케이스 ($\text{ovf} = 1$, 즉 $W_1 = -128 \wedge W_0 < 0$)

$A_{actual} = A_{port} + 2^{25}$, 따라서:

$$P_{int} = (A_{port} + 2^{25}) X = (W_1 X) \cdot 2^{17} + (W_0 X) + 2^{25} X \quad (\star\star)$$

**Claim A' ($W_0 X$ 자동 보호)**: $W_0 X = \operatorname{sint}_{17}(P_{int} \bmod 2^{17})$.

*증명.* $2^{25} X = 2^{17} \cdot 2^8 X \equiv 0 \pmod{2^{17}}$. Claim A 와 동일한 논증. $\square$

**Claim B' ($W_1 X$ 슬롯, 보정 후)**: $W_1 X = \operatorname{sint}_{16}(\lfloor P_{int}/2^{17}\rfloor \bmod 2^{16}) + [W_0 X < 0] - 256 X$.

*증명.* $(\star\star)$ 의 floor division:

$$\lfloor P_{int}/2^{17}\rfloor = W_1 X + 256 X + \lfloor W_0 X / 2^{17} \rfloor = W_1 X + 256 X - [W_0 X < 0]$$

(오버플로우 케이스에서는 항상 $W_0 < 0$ 이므로 $W_0 X$ 의 부호는 $X$ 의 부호에 따라 결정. 양쪽 케이스 모두 $W_0 X < 2^{14}$ 이며 floor 처리 동일.)

$|W_1 X + 256 X| = |X (W_1 + 256)| = |X \cdot 128| \le 128 \cdot 128 = 2^{14}$ (since $W_1 = -128$), 따라서 16-bit signed 범위 내. $\operatorname{sint}_{16}$ 적용 후 $[W_0 X < 0]$ 더하고 $256 X$ 빼면 $W_1 X$ 복원. $\square$

### 5.5 두 케이스 통합

알고리즘의 식 $P_1 = \operatorname{sint}_{16}(\lfloor P/2^{17}\rfloor \bmod 2^{16}) + [P_0 < 0] - 256 X \cdot \text{ovf}$ 는:
- $\text{ovf} = 0$: Claim B 와 동일 → $W_1 X$.
- $\text{ovf} = 1$: Claim B' 와 동일 → $W_1 X$.

모든 $(W_0, W_1, X) \in [-128, 127]^3$ 에 대해 정확. $\blacksquare$

## 6. 정확성 검증 (수치 실험)

전체 $2^{24} = 16{,}777{,}216$ 조합 Python 시뮬레이션, 0 오류.

## 7. 하드웨어 구현 시 주의사항

### 7.1 자원 비용 추정

| 항목 | 비용 | 비고 |
|:--|:--:|:--|
| DSP48E1 | 1개 | 두 곱셈 packing |
| $A_{port}$ 조립 (런타임) | ~8 LUT | 7.3절 (오프라인 시 0) |
| 오버플로우 검출 (런타임) | ~2 LUT | $W_1 = -128 \wedge W_0[7]$ |
| 오버플로우 검출 (pre-packed) | ~4 LUT | 7.3절 |
| 보정항 마스킹 ($-256 X \cdot \text{ovf}$) | ~8 LUT | upper 8-bit AND mask |
| 16-bit ternary adder ($P[32:17] + P[16] + \text{correction}$) | ~16–32 LUT | LUT6_2 활용 시 ~16, 일반 합성 시 ~30 |
| **추출 단 총합 (pre-packed)** | **~30–45 LUT** | |

Ternary adder 비용 범위가 큰 이유: Xilinx 7-series 는 LUT6_2 + CARRY4 조합으로 ternary 를 2-input adder 와 동등한 비용으로 추론 가능 (US patent 7274211, Vivado/XST 자동 추론). 단, 보정항이 조건부 마스킹된 입력일 경우 도구 선택에 따라 cascaded 2-step 으로 합성될 수 있어 보수적으로 더 큰 비용으로 잡는 것이 안전.

### 7.2 Critical Path 특성

방식 A 는 분기와 MUX 가 없는 **단일 경로** 구조이다:

$$\text{DSP output} \to \text{ternary adder (carry chain)} \to \text{output}$$

- 모든 입력 조합에서 동일한 데이터 경로
- DSP 출력과 외부 logic 간 latency 정렬 불필요 (조건부 경로 없음)
- Critical path 깊이: DSP 출력 후 1-level LUT + carry chain propagation

방식 B (분기 + MUX) 대비 장점:
- Latency matching FF 불필요 (~30 FF 절약)
- MUX delay 제거
- 합성 도구가 표준 산술 패턴으로 최적화하기 쉬움

### 7.3 $A_{port}$ 조립 및 오버플로우 검출 (Pre-packed 시나리오)

**$A_{port}$ 조립 (런타임)**: 정수 산술 $A_{port} = W_1 \cdot 2^{17} + W_0$ 의 비트 패턴은 단순 concatenation 이 아니다. $W_0 < 0$ 일 때 sign-extension 비트가 $W_1$ 영역으로 전파:

$$A_{port}[7:0] = W_0[7:0], \quad A_{port}[16:8] = \{9 \times W_0[7]\} \text{ (wire)}$$
$$A_{port}[24:17] = W_1 + (W_0 < 0\ ?\ -1 : 0) \text{ (8-bit 조건부 가감산)}$$

런타임 조립 약 8 LUT.

**Pre-packed weight 시나리오 (오프라인)**: 호스트에서 $A_{port}$ 를 미리 계산해 25-bit 형태로 메모리에 저장. 이 경우 $W_1$ 이 명시적으로 존재하지 않으므로 오버플로우 검출도 비트 패턴으로 수행:

$$\text{ovf} = [A_{port}[24:17] = \text{0x7F}] \wedge A_{port}[16]$$

검증: 이 시그니처는 오직 $W_1 = -128 \wedge W_0 < 0$ (오버플로우 케이스 128개) 에서만 발생하며, 다른 모든 케이스와 충돌하지 않음. 비용: 8-bit comparator + 1 AND, 약 4 LUT.

**참고**: 방식 B 는 $W_1 = -128$ 전체 (256 케이스) 를 검출해야 해서 두 시그니처 OR (~4–6 LUT) 가 필요한 반면, 방식 A 는 오버플로우 케이스 (128 케이스) 만 검출하므로 단일 시그니처로 더 단순.

### 7.4 보정항 $-256 X$ 의 구현

$-256 X$ 는 $X$ 를 9-bit signed 로 표현 후 부호 반전하고 8-bit shift 한 형태:
- $X$ 의 16-bit sign-extension: wire
- 부호 반전: 9-bit (X 가 -128 일 때 +128 표현 위해 9-bit 필요)
- 8-bit zero-pad: wire
- 마스킹 ($\text{ovf}$ 가 0 이면 모든 비트 0): 8-bit AND, ~8 LUT

전체 ~8–10 LUT.

## 8. 학계 대비 우위

| 비교 | 본 알고리즘 | Xilinx WP486 (DSP48E2) | Vestias FPL17 (DSP48E1) |
|:--|:--:|:--:|:--:|
| 대상 device | Artix-7 (DSP48E1) | UltraScale (DSP48E2) | Artix-7 (DSP48E1) |
| -128 처리 | ✓ 완벽 처리 | ✓ 처리 (27-bit) | ✗ 사실상 클리핑 |
| 양자화 손상 | 없음 | 없음 | -128 시 손상 |
| 데이터 경로 | 단일 (분기 없음) | 단일 | 단일 |
| 추가 logic | ~30–45 LUT | 0 | ~50 LUT |

## 9. 핵심 통찰

1. **모듈러 산술의 우연**: 오버플로우 오차 $2^{25} X$ 가 $2^{17}$ 의 배수. $W_0 \cdot X$ 슬롯 자동 보호.

2. **산술적 보정의 우아함**: 오버플로우 시 상위 슬롯에 더해지는 오차 $256 X$ 가 정확히 알 수 있는 값이므로 분기 없이 합산 단계에서 빼면 됨. 분기와 MUX 가 사라져 단일 데이터 경로 유지.

3. **결과**: DSP48E1 (25-bit) 에서도 모든 INT8 케이스를 손실 없이 처리. UltraScale 전용으로 알려진 INT8 SIMD packing 을 Artix-7 에서 ~30–45 LUT 추가 비용만으로 실현.