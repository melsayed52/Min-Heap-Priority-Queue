# Windows runner for the simulation (expects OSS CAD Suite).
# Usage:  .\run.ps1 [-Quick] [-Seed 101] [-CadSuite C:\path\to\oss-cad-suite]
param(
  [switch]$Quick,
  [int]$Seed = 1,
  [string]$CadSuite = "C:\Claude\Code\PQ\tools_dl\oss-cad-suite"
)
$root = Split-Path $PSScriptRoot -Parent
$q = if ($Quick) { "+quick" } else { "" }
cmd /c "call $CadSuite\environment.bat && cd /d $root && iverilog -g2005 -o sim\tb.vvp -s tb_pheap tb\tb_pheap.v rtl\pheap.v rtl\ram_dp.v && vvp sim\tb.vvp $q +seed=$Seed"
