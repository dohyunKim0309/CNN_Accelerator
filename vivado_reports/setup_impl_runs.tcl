# =====================================================================
#  setup_impl_runs.tcl  -- create named implementation runs (for report)
#
#  Use: open the project, then in the Tcl console:
#       source C:/Users/gimdohyeon/setup_impl_runs.tcl
#  -> self-describing runs appear in the Design Runs panel; launch what you want.
#
#  Re-sourcing is SAFE: existing runs are SKIPPED (not deleted), so it never
#  errors on a running run. To recreate one with new settings:
#       delete_runs <name>     (must be stopped/idle) then re-source.
#
#  ---------------------------------------------------------------------
#  SCOPE (read this): what these runs compare
#   - baseline (cnn_accelerator.v) vs winograd (_winograd.v) differ at SYNTH
#     (top is a packaged IP). One synth_1 = one variant -> these runs all
#     compare IMPLEMENTATION RECIPES on "that synth_1 + the current clk_out3".
#   - Frequency (200 vs 171.43 MHz) lives in the clk_wiz IP / XDC create_clock,
#     NOT in an impl run -> it cannot be changed here (needs re-synthesis).
#   - Old RTL iterations (folders 02..07) had different RTL -> not reproducible
#     by impl-run alone; cite the saved NN_*/*.rpt instead.
#  ---------------------------------------------------------------------
#
#  REQUIRED: copy ALL THREE files to $hookdir (below):
#     setup_impl_runs.tcl , over_constrain_clk.tcl , deconstrain_clk.tcl
#  (the over/deconstrain hooks are sourced by the run itself during place/phys_opt)
#  (ASCII only -- Windows Vivado console may mangle non-ASCII text.)
# =====================================================================

set hookdir "C:/Users/gimdohyeon"   ;# folder that holds over/deconstrain_clk.tcl

# --- auto-detect from the project (robust to run/constrset names) ---
set ref_impl [lindex [get_runs -filter {IS_IMPLEMENTATION}] 0]
set implflow [get_property FLOW      $ref_impl]
set cset     [get_property CONSTRSET $ref_impl]
set synthrun [lindex [get_runs -filter {IS_SYNTHESIS}] 0]
puts "ref impl=$ref_impl  flow=$implflow  constrset=$cset  synth=$synthrun"

# --- reusable proc: create one named run (skips if it already exists) ---
#  name      display name in Design Runs (keep it self-describing)
#  place_dir place_design directive (Default/Explore/ExtraTimingOpt/...)
#  route_dir route_design directive (Default/Explore/...)
#  pp        post-place  phys_opt enable (1/0)
#  prp       post-route  phys_opt enable (1/0)
#  oc        use over-constrain hooks    (1/0)
proc mk_impl {name place_dir route_dir pp prp oc} {
    global hookdir implflow cset synthrun
    if {[llength [get_runs -quiet $name]]} {
        puts "  skip: '$name' already exists (delete_runs $name to recreate)"
        return
    }
    create_run $name -parent_run $synthrun -flow $implflow -constrset $cset
    set r [get_runs $name]
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE           $place_dir            $r
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE           $route_dir            $r
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED            [expr {$pp  ? 1 : 0}] $r
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED [expr {$prp ? 1 : 0}] $r
    if {$oc} {
        set_property STEPS.PLACE_DESIGN.TCL.PRE "$hookdir/over_constrain_clk.tcl" $r
        if {$prp} {
            set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.PRE "$hookdir/deconstrain_clk.tcl" $r
        } else {
            set_property STEPS.ROUTE_DESIGN.TCL.POST "$hookdir/deconstrain_clk.tcl" $r
        }
    }
    puts "  created: $name  (place=$place_dir route=$route_dir pp=$pp prp=$prp oc=$oc)"
}

# --- preset runs for the report --------------------------------------
#  (1) tool-default floor (no phys_opt, no over-constrain)
mk_impl impl_stock_ref      Default        Default  0 0 0
#  (2) strong directives + phys_opt, NO over-constrain (honest ceiling)
mk_impl impl_extraTO_noOC   ExtraTimingOpt Explore  1 1 0
#  (3) * the recipe that closed = (2) + over-constrain +0.700 (only oc differs)
#      so the (2) vs (3) WNS gap = the pure contribution of over-constraining
mk_impl impl_oc700_signoff  ExtraTimingOpt Explore  1 1 1

puts "--------------------------------------------------------------------"
puts "Created in Design Runs. Run / inspect:"
puts "  launch_runs impl_oc700_signoff -jobs 8"
puts "  wait_on_run impl_oc700_signoff        ;# pass the run NAME (or just watch the GUI)"
puts "  open_run    impl_oc700_signoff"
puts "  report_timing_summary                 ;# this WNS == the Design Runs column"
puts "  report_clocks                         ;# clk_out3 actual period (snap check!)"
puts "  current_run -implementation \[get_runs impl_oc700_signoff\]  ;# make it the active/main run"
