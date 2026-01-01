#!/bin/bash

CONQUEST_ROOT="/home/m4ul3r/conquest"
nim --os:windows \
    --cpu:amd64  \
    --gcc.exe:x86_64-w64-mingw32-gcc \
    --gcc.linkerexe:x86_64-w64-mingw32-gcc \
    c $CONQUEST_ROOT/src/agent/main.nim