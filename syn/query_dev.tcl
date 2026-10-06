# quick device-geometry query for floorplanning (no synthesis)
set part xc7a100tcsg324-1
link_design -part $part
puts "CLKREGIONS:"
foreach cr [lsort [get_clock_regions]] { puts "  $cr" }
# BRAM tile columns (RAMB36 sites): report unique X columns and Y span
set xs {}
foreach s [get_sites -filter {SITE_TYPE == RAMB36}] {
  regexp {X(\d+)Y(\d+)} $s -> x y
  lappend xs $x
}
set uniq [lsort -integer -unique $xs]
puts "RAMB36_COLS(X): $uniq   count=[llength [get_sites -filter {SITE_TYPE==RAMB36}]]"
# SLICE extent
set sx {}; set sy {}
foreach s [get_sites -filter {SITE_TYPE =~ SLICE*}] {
  regexp {X(\d+)Y(\d+)} $s -> x y; lappend sx $x; lappend sy $y
}
puts "SLICE X: [lindex [lsort -integer $sx] 0] .. [lindex [lsort -integer $sx] end]"
puts "SLICE Y: [lindex [lsort -integer $sy] 0] .. [lindex [lsort -integer $sy] end]"
