# =====================================================================
#  over_constrain_clk.tcl  -- implementation 'Place Design' PRE hook
#
#  Purpose: inflate setup uncertainty during place/phys_opt/route so the
#           tools work harder (over-constrain). Applies to THIS run's
#           in-memory timing only; it is NOT written to the XDC.
#
#  Pair   : deconstrain_clk.tcl must restore it to 0 before signoff, so
#           the Design Runs WNS column shows the REAL-constraint value.
#
#  Note   : if the clock name differs, edit the one line below
#           (check with: report_clocks).
#  (ASCII only -- Windows Vivado console may mangle non-ASCII comments.)
# =====================================================================

set occlk [get_clocks -quiet clk_out3_cnn_accelerator_system_clk_wiz_0_0]
if {[llength $occlk] == 0} {
    error "over_constrain_clk: clk_out3 clock not found -- check clock name (report_clocks)"
}
set_clock_uncertainty -setup 0.700 $occlk
puts "\[hook\] OVER-CONSTRAIN : +0.700ns setup uncertainty on $occlk"
