# =====================================================================
#  over_constrain_clk.tcl   — implementation 'Place Design' 단계 PRE 훅
#
#  목적: place / phys_opt / route 동안 setup uncertainty 를 인위로 키워
#        (over-constrain) tool 을 더 굴린다.
#        → 이 run 의 in-memory 타이밍에만 적용, XDC 에는 저장 안 됨.
#
#  짝꿍: deconstrain_clk.tcl 가 signoff(최종 리포트) 전에 0 으로 되돌려야
#        Design Runs 의 WNS 열이 '실제 제약' 값으로 나온다.
#
#  주의: 클럭명이 다르면 아래 한 줄만 고치면 됨. (report_clocks 로 확인)
# =====================================================================

set occlk [get_clocks -quiet clk_out3_cnn_accelerator_system_clk_wiz_0_0]
if {[llength $occlk] == 0} {
    error "over_constrain_clk: clk_out3 클럭을 못 찾음 — 클럭명을 확인하세요 (report_clocks)"
}
set_clock_uncertainty -setup 0.700 $occlk
puts "\[hook] OVER-CONSTRAIN : +0.700ns setup uncertainty on $occlk"
