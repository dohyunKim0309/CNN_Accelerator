# =============================================================================
# wino_floorplan.tcl — conv2 winograd B·D 벽 floorplan (XDC, RTL 0 변경)
#   설계: docs/winograd/conv2_winograd_floorplan.md
#   ★ placed/routed design 이 열린 상태에서 파일로 source (콘솔 멀티라인 붙여넣기 함정 회피):
#        source C:/Users/gimdohyeon/wino_floorplan.tcl
#
#   PART 1 = 진단(읽기만, 100% 안전). 각 그룹의 현 SLICE bbox + clock region 출력.
#   PART 2 = pblock 생성 (맨 아래, ★주석 처리됨). PART 1 출력으로 CR_RANGE 채운 뒤 해제.
#
#   ※ bisect 후 netlist 에서 돌릴 것. (siml_/simh_/accH_/gpH_/car_ 는 bisect 에만 존재 —
#     pre-bisect 06 checkpoint 에선 0 cells 로 떠도 정상.)
# =============================================================================

# pin 대상 = conv2 timing-critical core (가산기 로직). lane DSP/weight RAM 은 float.
#  ★ 진단과 PART 2 가 같은 리스트를 쓰도록 한 곳에 정의 (보고==고정 보장).
#  ※ NAME =~ 는 string-match → '[' ']' 는 char-class 이므로 gic[0] 대신 gic* 로 회피.
set CORE_PATS {
    gic*u_it/*
    tile6_q_reg*
    grp_q*
    gp*
    acc_*
    msum*
    gbis*
    siml_*
    simh_*
    accH_*
    gpH_*
    car_*
    u_asm/*
    m_re_flat*
    m_im_flat*
}

proc core_cells {pat} {
    return [get_cells -quiet -hierarchical -filter "NAME =~ */conv2/$pat"]
}

proc report_group {label pat} {
    set cells [core_cells $pat]
    set n [llength $cells]
    if {$n == 0} { puts [format "  %-16s : %5d  (pattern: conv2/%s)" $label 0 $pat] ; return }
    # ★ list-로 한 번에 LOC 추출(빠름) + get_clock_regions 안 씀(셀 리스트에 에러내는 경우 회피).
    set xs {} ; set ys {}
    foreach loc [get_property -quiet LOC $cells] {
        if {[regexp {SLICE_X(\d+)Y(\d+)} $loc -> x y]} { lappend xs $x ; lappend ys $y }
    }
    if {[llength $xs] == 0} {
        puts [format "  %-16s : %5d cells | (unplaced/non-SLICE)" $label $n]
    } else {
        set xs [lsort -integer $xs] ; set ys [lsort -integer $ys]
        puts [format "  %-16s : %5d cells | SLICE X%d..%d Y%d..%d" \
              $label $n [lindex $xs 0] [lindex $xs end] [lindex $ys 0] [lindex $ys end]]
    }
}

puts "==================== conv2 floorplan 진단 (PART 1) ===================="
catch { puts "device = [get_property PART [current_design]]" }
report_group "IT(gic.u_it)" "gic*u_it/*"
report_group "tile6_q"      "tile6_q_reg*"
report_group "grp_q"        "grp_q*"
report_group "gather(gp*)"  "gp*"
report_group "acc"          "acc_*"
report_group "msum"         "msum*"
report_group "bisect"       "gbis*"
report_group "  siml"       "siml_*"
report_group "  simh/accH"  "simh_*"
report_group "m_assemble"   "u_asm/*"
report_group "m_*_flat"     "m_re_flat*"
report_group "m_im_flat"    "m_im_flat*"
report_group "lane(DSP)"    "lane*u_mul/*"
puts "----------------------------------------------------------------------"
puts "★ 'reduce'(acc/msum/m_*_flat/u_asm) 가 있는 CR 을 anchor 로 PART 2 의 CR_RANGE 결정."
puts "   = 그 CR + 세로 이웃 1개 (예: reduce 가 X1Y2 면  X1Y1:X1Y2).  과밀(util>90%)이면 1개 더."
puts "   core 전체 cell 수 / 잔여 음수 path 는 report_timing_summary 로 별도 확인."
puts "======================================================================"

# =============================================================================
# PART 2 — pblock 생성·할당 (★ 아래 CR_RANGE 를 PART 1 출력으로 채운 뒤 전체 주석 해제)
# =============================================================================
#
# set CR_RANGE {CLOCKREGION_X1Y1:CLOCKREGION_X1Y2}   ;# ← reduce CR + 세로 이웃 (PART 1 보고 수정)
#
# catch {delete_pblock pb_conv2_core}
# create_pblock pb_conv2_core
# foreach p $CORE_PATS {
#     set cs [core_cells $p]
#     if {[llength $cs]} { add_cells_to_pblock pb_conv2_core $cs }
# }
# resize_pblock pb_conv2_core -add $CR_RANGE
# # 처음엔 SOFT(advisory)로 시험 → overflow 시 place 실패 대신 spill. 효과 보이면 hard 로:
# set_property IS_SOFT TRUE [get_pblocks pb_conv2_core]
# report_utilization -pblocks [get_pblocks pb_conv2_core]
# puts "pb_conv2_core: [llength [get_cells -quiet -of [get_pblocks pb_conv2_core]]] cells, range=$CR_RANGE"
# puts "→ place_design 재실행(또는 reset_run+launch) 후 report_timing_summary 로 B(grp_q/tile6_q→tre)·D route 확인."
#
# # ---- XDC 로 영구 저장 (place 결과 만족 시) ----
# # write_xdc -force C:/Users/gimdohyeon/wino_floorplan.xdc   ;# → 프로젝트 XDC 로 add
