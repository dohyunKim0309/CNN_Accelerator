# =============================================================================
# wino_paths146.tcl — 200MHz WNS -0.146 / 13 EP 정밀 추출 (Vivado 2024.1)
#   ★ routed design 이 열린 상태에서:
#        source C:/Users/gimdohyeon/wino_paths146.tcl
#   (콘솔 멀티라인 붙여넣기 함정 회피용 — 반드시 파일로 source 할 것)
#
# 출력 4개 (OUT 디렉터리에):
#   wino_ts_146.rpt      : timing summary (WNS/TNS/failing EP 재확인)
#   wino_paths146.rpt    : 실패 13 path 상세 (-input_pins -nets, logic/route 분해)
#   wino_da_146.rpt      : worst 10 의 logic%/net% + High Fanout 열 (max_fanout vs 파이프 판정)
#   wino_strata_146.rpt  : endpoint 클래스별 [worst slack | count] 지층표 (13 EP 가 어느 클래스인지)
# =============================================================================
set OUT "C:/Users/gimdohyeon"

# 1) 요약
report_timing_summary -delay_type max -max_paths 13 -file $OUT/wino_ts_146.rpt

# 2) 실패 endpoint 전체 상세 (slack<0 만, endpoint 당 1 worst)
report_timing -setup -slack_lesser_than 0 -max_paths 50 -nworst 1 -unique_pins \
              -input_pins -nets -file $OUT/wino_paths146.rpt

# 3) logic%/net% + High Fanout 분해 (worst 10)
report_design_analysis -timing -max_paths 10 -file $OUT/wino_da_146.rpt

# 4) 클래스 지층표 — 13 EP 가 어느 클래스에 몰렸는지 한눈에
set paths [get_timing_paths -setup -max_paths 2000 -nworst 1 -unique_pins -slack_lesser_than 0]
puts "INFO: failing endpoint paths = [llength $paths]"
array unset CNT ; array unset WSL
foreach p $paths {
    set ep  [get_property ENDPOINT_PIN $p]
    set sl  [get_property SLACK $p]
    set key $ep
    regsub {^.*cnn_accelerator_wino_0/inst/} $key "" key
    set key [join [lrange [split $key "/"] 0 end-1] "/"]
    regsub -all {\[[0-9]+\]} $key "" key
    if {![info exists CNT($key)]} { set CNT($key) 0 ; set WSL($key) 0.0 }
    incr CNT($key)
    if {$sl < $WSL($key)} { set WSL($key) $sl }
}
set rows {}
foreach key [array names CNT] { lappend rows [list $WSL($key) $CNT($key) $key] }
set fp [open "$OUT/wino_strata_146.rpt" w]
puts $fp [format "%-10s %8s   %s" "worstSlack" "count" "endpoint-class"]
puts $fp [string repeat - 90]
foreach row [lsort -real -index 0 $rows] {
    puts $fp [format "%10.3f %8d   %s" [lindex $row 0] [lindex $row 1] [lindex $row 2]]
}
close $fp
puts "DONE — wino_ts_146 / wino_paths146 / wino_da_146 / wino_strata_146 → $OUT"
