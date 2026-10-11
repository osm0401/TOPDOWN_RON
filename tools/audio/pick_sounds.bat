@echo off
rem Opens the take-picking tool (listen, then mark use / skip). Needs the generated takes in assets\audio\_raw.
"D:\Godot\Godot_v4.7.2-stable_win64.exe" --path "%~dp0..\.." res://tools/audition/audition.tscn
