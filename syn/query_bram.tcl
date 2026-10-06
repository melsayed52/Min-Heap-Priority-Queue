link_design -part xc7a100tcsg324-1
set xs {}
foreach s [get_sites RAMB36_*] { regexp {X(\d+)Y(\d+)} $s -> x y; lappend xs $x }
puts "RAMB36_COLS: [lsort -integer -unique $xs]  total=[llength [get_sites RAMB36_*]]"
set xs18 {}
foreach s [get_sites RAMB18_*] { regexp {X(\d+)Y(\d+)} $s -> x y; lappend xs18 $x }
puts "RAMB18_COLS: [lsort -integer -unique $xs18]"
