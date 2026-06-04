#include "platform.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include <stdint.h>

// ============================================================================
// Base addresses — Vivado 블록 디자인의 xparameters.h 값으로 교체할 것
// ============================================================================
#define CSR_BASE         0x44A00000U   // AXI4-Lite CSR
#define BRAM_INPUT_BASE  0xC0000000U   // bram_input   Port A (32b x 512)
#define BRAM_C1W_BASE    0xC0010000U   // conv1 weight BRAM Port A (32b x 64)
#define BRAM_C2W_BASE    0xC0020000U   // conv2 weight BRAM Port A (32b x 1024)
#define BRAM_FCW_BASE    0xC0030000U   // FC weight BRAM Port A   (32b x 8192)

// ============================================================================
// BRAM 크기 (32-bit word 단위)
// ============================================================================
#define INPUT_WORDS   196U   // 28x28 = 784 pixels, 4 bytes/word → 784/4 = 196 words
#define C1W_WORDS      36U   // conv1_weight_loader addr 0~35
#define C2W_WORDS     576U   // weight_loader_conv2  addr 0~575
#define FCW_WORDS    5760U   // 720 논리 엔트리 × 8 (32b words/256b entry)

// ============================================================================
// CSR 레지스터 오프셋
// ============================================================================
#define CSR_CTRL_OFFSET  0x0U   // [1]=start(pulse), [0]=enable(level)
#define CSR_STAT_OFFSET  0x4U   // [4:1]=result, [0]=done
#define CSR_TLO_OFFSET   0x8U   // timer[31:0]
#define CSR_THI_OFFSET   0xCU   // {16'd0, timer[47:32]}

// CTRL 비트 마스크
#define CTRL_ENABLE  0x1U
#define CTRL_START   0x2U

// STATUS 필드
#define STAT_DONE_MASK    0x1U
#define STAT_RESULT_SHIFT 1U
#define STAT_RESULT_MASK  (0xFU << STAT_RESULT_SHIFT)

// ============================================================================
// 입력 / 가중치 헤더 (별도 파일로 준비)
// ============================================================================
#include "input_image.h"    // const int8_t  input_image[784];   (28x28 pixels, int8)
#include "conv1_weights.h"  // const uint32_t conv1_weights[36];
#include "conv2_weights.h"  // const uint32_t conv2_weights[576];
#include "fc_weights.h"     // const uint32_t fc_weights[5760];  (720 entries × 8 words)

static const char *class_names[10] = {
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck"
};

int main(void)
{
    init_platform();
    Xil_DCacheDisable();

    xil_printf("\r\n=== CNN Accelerator Single Image Test ===\r\n");

    // 1. Conv1 weight 적재 (36 words)
    xil_printf("[1] Loading conv1 weights (%u words)...\r\n", (unsigned)C1W_WORDS);
    for (u32 i = 0U; i < C1W_WORDS; i++) {
        Xil_Out32(BRAM_C1W_BASE + i * 4U, conv1_weights[i]);
    }

    // 2. Conv2 weight 적재 (576 words)
    xil_printf("[2] Loading conv2 weights (%u words)...\r\n", (unsigned)C2W_WORDS);
    for (u32 i = 0U; i < C2W_WORDS; i++) {
        Xil_Out32(BRAM_C2W_BASE + i * 4U, conv2_weights[i]);
    }

    // 3. FC weight 적재 (5760 words = 720 × 8)
    xil_printf("[3] Loading FC weights (%u words)...\r\n", (unsigned)FCW_WORDS);
    for (u32 i = 0U; i < FCW_WORDS; i++) {
        Xil_Out32(BRAM_FCW_BASE + i * 4U, fc_weights[i]);
    }

    // 4. 입력 이미지 적재 (784 int8 pixels → 196 words, little-endian packing)
    //    Port A 32b 쓰기 → Port B 8b 읽기 시 byte 0 = bits[7:0], byte 1 = bits[15:8], ...
    xil_printf("[4] Loading input image (28x28)...\r\n");
    for (u32 i = 0U; i < INPUT_WORDS; i++) {
        u32 word = ((u32)(u8)input_image[i * 4U + 0U])        |
                   ((u32)(u8)input_image[i * 4U + 1U] << 8U)  |
                   ((u32)(u8)input_image[i * 4U + 2U] << 16U) |
                   ((u32)(u8)input_image[i * 4U + 3U] << 24U);
        Xil_Out32(BRAM_INPUT_BASE + i * 4U, word);
    }

    // 5. enable 설정 (level)
    xil_printf("[5] Setting enable...\r\n");
    Xil_Out32(CSR_BASE + CSR_CTRL_OFFSET, CTRL_ENABLE);

    // 6. start pulse 발생 (CTRL[1]=1, hw가 다음 cycle auto-clear)
    xil_printf("[6] Sending START pulse...\r\n");
    Xil_Out32(CSR_BASE + CSR_CTRL_OFFSET, CTRL_ENABLE | CTRL_START);

    // 7. done 폴링 (STATUS[0] == 1 까지 대기)
    xil_printf("[7] Waiting for DONE...\r\n");
    u32 status;
    do {
        status = Xil_In32(CSR_BASE + CSR_STAT_OFFSET);
    } while ((status & STAT_DONE_MASK) == 0U);
    xil_printf("[7] DONE received!\r\n");

    // 8. 결과 및 타이머 읽기
    u32 pred    = (status & STAT_RESULT_MASK) >> STAT_RESULT_SHIFT;
    u32 tlo     = Xil_In32(CSR_BASE + CSR_TLO_OFFSET);
    u32 thi     = Xil_In32(CSR_BASE + CSR_THI_OFFSET);
    u64 cycles  = ((u64)thi << 32U) | (u64)tlo;

    // 9. 결과 출력
    xil_printf("\r\n=== Result ===\r\n");
    xil_printf("Predicted class : %u", (unsigned)pred);
    if (pred < 10U)
        xil_printf(" (%s)", class_names[pred]);
    xil_printf("\r\n");
    xil_printf("Elapsed cycles  : %llu\r\n", (unsigned long long)cycles);

    cleanup_platform();
    return 0;
}
