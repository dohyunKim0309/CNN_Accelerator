# =====================================================================
#  deconstrain_clk.tcl  -- 'Post-Route Phys Opt Design' PRE hook
#                          (or the Route POST hook if post-route phys_opt
#                           is disabled)
#
#  Purpose: remove the over-constrain before signoff, so this step and the
#           final timing summary (the source of the Design Runs WNS column)
#           are reported at the REAL constraint.
#           If not removed, the column shows (realWNS - 0.700), i.e. a red
#           negative number.
#  (ASCII only -- Windows Vivado console may mangle non-ASCII comments.)
# =====================================================================

set occlk [get_clocks -quiet clk_out3_cnn_accelerator_system_clk_wiz_0_0]
if {[llength $occlk] == 0} {
    error "deconstrain_clk: clk_out3 clock not found -- check clock name (report_clocks)"
}
set_clock_uncertainty -setup 0.000 $occlk
puts "\[hook\] DE-CONSTRAIN  : setup uncertainty -> 0.000 on $occlk (signoff)"
