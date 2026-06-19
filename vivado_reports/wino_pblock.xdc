# =============================================================================
# wino_pblock.xdc — conv2 floorplan, Iteration 1b (M·D 벽, 밀도벽 대응판)
#   설계: docs/winograd/conv2_winograd_floorplan.md
#   1a 실패 원인 2개 수정:
#     ① 1칸(X1Y2)은 DSP열+lane(LUT88%)이라 reduce 추가시 overflow → place 실패
#        → 3칸(우측열 X1Y1:X1Y3)으로 넓힘(room) + X 를 X56-89 로 bound(placer 가 X0 산개 못 함).
#     ② m_assemble carry 셀이 synth 로 'cnn_accelerator_wino_0/u_asm/' (conv2 밖)으로 떠서
#        '*/conv2/u_asm/*' 가 놓침 → carry-chain 이 pblock 안팎으로 쪼개짐(Place 30-439).
#        → 패턴을 '*u_asm/*' '*m_im_flat*' '*m_re_flat*' 로 넓혀 떠버린 셀까지 포함.
#   IS_SOFT TRUE = place 실패 위험 회피(우선). place 후 bbox 로 X56-89 압축 확인 → 약하면 hard.
# =============================================================================

catch {delete_pblock pb_reduce}
create_pblock pb_reduce

# gather/acc/msum : conv2 내부 (안 떠 있음)
foreach p {gp* acc_* msum*} {
    set cs [get_cells -quiet -hierarchical -filter "NAME =~ */conv2/$p"]
    if {[llength $cs]} { add_cells_to_pblock pb_reduce $cs }
}
# m_assemble + M출력 : conv2 안 + wino_0 레벨로 뜬 carry 셀까지 (★split 회피)
foreach p {*u_asm/* *m_re_flat* *m_im_flat*} {
    set cs [get_cells -quiet -hierarchical -filter "NAME =~ $p"]
    if {[llength $cs]} { add_cells_to_pblock pb_reduce $cs }
}

# ★ 3 CR (우측열 행1-3 = SLICE X56-89 / Y50-199) — room + X bound
resize_pblock pb_reduce -add CLOCKREGION_X1Y1:CLOCKREGION_X1Y3
set_property IS_SOFT TRUE [get_pblocks pb_reduce]
report_utilization -pblocks [get_pblocks pb_reduce]
