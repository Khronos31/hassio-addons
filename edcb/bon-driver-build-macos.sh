#!/bin/sh
# Linux版はDockerfileの `g++ -shared` のまま。このスクリプトはmacOS専用。
set -eu

g++ -std=c++17 -fPIC -dynamiclib -o BonDriver_S1UD.dylib BonDriver_S1UD.cpp -pthread
g++ -std=c++17 -fPIC -dynamiclib -o BonDriver_Px4_T.dylib BonDriver_Px4.cpp -pthread
g++ -std=c++17 -fPIC -dynamiclib -DPX4_BONDRIVER_SATELLITE=1 -o BonDriver_Px4_S.dylib BonDriver_Px4.cpp -pthread
