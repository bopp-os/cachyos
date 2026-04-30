#!/usr/bin/env bash

set -xeuo pipefail

git clone "https://github.com/bootc-dev/bootc.git" .
 
make bin install-all DESTDIR=/output

