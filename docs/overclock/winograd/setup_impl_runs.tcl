# =====================================================================
#  setup_impl_runs.tcl  — 보고서용 'named' implementation run 묶음 생성
#
#  사용: 프로젝트 열고 Tcl 콘솔에서
#        source C:/Users/gimdohyeon/setup_impl_runs.tcl
#        → Design Runs 패널에 자기설명적 이름의 run 들이 생김. 골라서 launch.
#
#  ─────────────────────────────────────────────────────────────────────
#  ★ 범위(꼭 이해): 이 run 들이 '무엇'을 비교하는가
#   - baseline(cnn_accelerator.v) ↔ winograd(_winograd.v) 는 SYNTH 가 다름
#     (top 이 packaged IP). 한 프로젝트의 synth_1 은 '지금 패키징된 변형'
#     하나만 반영 → 아래 run 은 전부 "그 synth_1 + 현재 clk_out3 제약"에
#     대한 **구현 레시피 비교**다. (변형 바꾸려면 re-package + BD upgrade + 재합성)
#   - 주파수(200 vs 171.43MHz)는 clk_wiz IP / XDC create_clock 레벨 → impl
#     run 으로는 못 바꿈. 즉 이 run 들은 '같은 주파수 목표에서 어느 레시피가
#     가장 잘 닫나'를 보는 용도. (현재 synth 가 어느 주파수인지는 report_clocks)
#   - 과거 RTL 이터레이션(02~07 폴더)은 RTL 자체가 달라서 impl-run 만으로는
#     재현 불가 — 그건 vivado_reports/NN_*/ 의 저장된 .rpt 를 그대로 인용.
#  ─────────────────────────────────────────────────────────────────────

set hookdir "C:/Users/gimdohyeon"   ;# ← over_constrain_clk.tcl / deconstrain_clk.tcl 둔 폴더

# --- 프로젝트에서 자동 추론 (run/constrset 이름이 달라도 안전) ---
set ref_impl [lindex [get_runs -filter {IS_IMPLEMENTATION}] 0]
set implflow [get_property FLOW      $ref_impl]
set cset     [get_property CONSTRSET $ref_impl]
set synthrun [lindex [get_runs -filter {IS_SYNTHESIS}] 0]
puts "ref impl=$ref_impl  flow=$implflow  constrset=$cset  synth=$synthrun"

# --- 재사용 proc: named run 하나 생성 ---
#  name      Design Runs 표시명 (자기설명적으로!)
#  place_dir place_design directive   (Default / Explore / ExtraTimingOpt / ...)
#  route_dir route_design directive   (Default / Explore / ...)
#  pp        post-place  phys_opt 활성 (1/0)
#  prp       post-route  phys_opt 활성 (1/0)
#  oc        over-constrain 훅 사용    (1/0)
proc mk_impl {name place_dir route_dir pp prp oc} {
    global hookdir implflow cset synthrun
    if {[llength [get_runs -quiet $name]]} {
        puts "WARN: '$name' 이미 존재 → 삭제 후 재생성 (기존 결과 사라짐)"
        delete_runs $name
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
            # 권장: 마지막 단계(post-route phys_opt) 직전에 de-constrain → 열이 깨끗
            set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.TCL.PRE "$hookdir/deconstrain_clk.tcl" $r
        } else {
            set_property STEPS.ROUTE_DESIGN.TCL.POST "$hookdir/deconstrain_clk.tcl" $r
        }
    }
    puts "  created: $name  (place=$place_dir route=$route_dir pp=$pp prp=$prp oc=$oc)"
}

# --- 보고서용 preset run ------------------------------------------------
#  (1) 비교 기준선: tool 기본 (directive 기본, phys_opt/over-constrain 없음)
mk_impl impl_stock_ref      Default        Default  0 0 0
#  (2) 강한 directive + phys_opt 만 — over-constrain 'X' (정직하게 어디까지)
mk_impl impl_extraTO_noOC   ExtraTimingOpt Explore  1 1 0
#  (3) ★ 실제로 닫은 레시피 = (2) + over-constrain '+0.700' (오직 oc 만 차이)
#      → (2) vs (3) 비교가 곧 'over-constrain 의 순(純) WNS 기여'
mk_impl impl_oc700_signoff  ExtraTimingOpt Explore  1 1 1

puts "--------------------------------------------------------------------"
puts "Design Runs 에 생성됨. 실행/확인 예:"
puts "  launch_runs impl_oc700_signoff -jobs 8 ; wait_on_run impl_oc700_signoff"
puts "  open_run    impl_oc700_signoff"
puts "  report_timing_summary               ;# 이 WNS == Design Runs 열과 같아야 함"
puts "  report_clocks                       ;# clk_out3 실제 period (snap 점검!)"
puts "  report_utilization -file impl_oc700_signoff_util.rpt"
puts "  report_power       -file impl_oc700_signoff_power.rpt"
puts "다른 over-constrain 값이 필요하면 over_constrain_clk.tcl 을"
puts "over_constrain_500.tcl 등으로 복사(0.700->0.500)하고 mk_impl 한 줄 추가."
