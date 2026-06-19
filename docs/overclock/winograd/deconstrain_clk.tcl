# =====================================================================
#  deconstrain_clk.tcl   — 'Post-Route Phys Opt Design' 단계 PRE 훅
#                          (post-route phys_opt 를 끈 경우엔 Route 의 POST 훅)
#
#  목적: signoff 전에 over-constrain 을 제거 → 이 단계와 그 단계가 만드는
#        최종 timing summary(= Design Runs 의 WNS 열 출처)가 '실제 제약'으로
#        나오게 한다. 안 빼면 열에 (실제WNS − 0.700) 즉 음수가 떠서 빨갛게 보임.
#
#  원리: place/post-place-phys_opt/route 는 +0.700 으로 빡세게 돌고,
#        이 단계 직전에 0 으로 복원 → 마지막 단계+리포트는 실제 제약.
# =====================================================================

set occlk [get_clocks -quiet clk_out3_cnn_accelerator_system_clk_wiz_0_0]
if {[llength $occlk] == 0} {
    error "deconstrain_clk: clk_out3 클럭을 못 찾음 — 클럭명을 확인하세요 (report_clocks)"
}
set_clock_uncertainty -setup 0.000 $occlk
puts "\[hook] DE-CONSTRAIN  : setup uncertainty -> 0.000 on $occlk (signoff)"
