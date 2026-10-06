set fp [open "syn/parts_list.txt" w]
foreach p [get_parts] { puts $fp $p }
close $fp
