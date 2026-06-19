# =============================================================================
# wino_strata.tcl — 실패 경로 "지층" 분석 (Vivado 2024.1)
#   routed design 이 열린 상태에서:   source C:/Users/gimdohyeon/wino_strata.tcl
#   (콘솔 멀티라인 붙여넣기 함정 회피용 — 반드시 파일로 source 할 것)
#
# 출력 2개 (OUT_DIR):
#   wino_strata_summary.rpt : endpoint 클래스별 [worst slack | 개수] 표 (지층 한눈에)
#   wino_paths_noOT.rpt     : 출력변환(u_ot) 제외 worst 100 path 상세 (-input_pins -nets)
# =============================================================================

set OUT_DIR "C:/Users/gimdohyeon"
set MAXP    6000

puts "INFO: collecting up to $MAXP failing paths (nworst 1, unique_pins) ..."
set paths [get_timing_paths -setup -max_paths $MAXP -nworst 1 -unique_pins -slack_lesser_than 0]
puts "INFO: got [llength $paths] failing endpoint paths"

array unset CNT
array unset WSL
set sel_noot {}

foreach p $paths {
    set ep [get_property ENDPOINT_PIN $p]
    set sl [get_property SLACK $p]

    # ---- 버킷 키: 가속기 prefix 제거 → 마지막 핀 이름 제거 → [인덱스] 제거 ----
    set key $ep
    regsub {^.*cnn_accelerator_wino_0/inst/} $key "" key
    set key [join [lrange [split $key "/"] 0 end-1] "/"]
    regsub -all {\[[0-9]+\]} $key "" key

    if {![info exists CNT($key)]} { set CNT($key) 0 ; set WSL($key) 0.0 }
    incr CNT($key)
    if {$sl < $WSL($key)} { set WSL($key) $sl }

    # ---- 출력변환 제외 worst 100 수집 ----
    if {![string match "*u_ot*" $ep] && [llength $sel_noot] < 100} {
        lappend sel_noot $p
    }
}

# ---- 지층표 (worst slack 오름차순 = 심각한 클래스부터) ----
set rows {}
foreach key [array names CNT] {
    lappend rows [list $WSL($key) $CNT($key) $key]
}
set fp [open "$OUT_DIR/wino_strata_summary.rpt" w]
puts $fp [format "%-10s %8s   %s" "worstSlack" "count" "endpoint-class"]
puts $fp [string repeat - 90]
foreach row [lsort -real -index 0 $rows] {
    puts $fp [format "%10.3f %8d   %s" [lindex $row 0] [lindex $row 1] [lindex $row 2]]
}
close $fp
puts "INFO: wrote $OUT_DIR/wino_strata_summary.rpt ([llength $rows] classes)"

# ---- OT 제외 worst 100 상세 ----
if {[llength $sel_noot] > 0} {
    report_timing -of_objects $sel_noot -input_pins -nets -file "$OUT_DIR/wino_paths_noOT.rpt"
    puts "INFO: wrote $OUT_DIR/wino_paths_noOT.rpt ([llength $sel_noot] paths)"
} else {
    puts "INFO: no non-OT failing paths found (!)"
}
puts "DONE"
