#!/bin/bash

if [ -z $1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

FILES="bin/qdb.pl qdb.conf.sample README public/"
QDB="qdb-$1"

mkdir $QDB
cp -ar $FILES $QDB
tar cvf $QDB.tar $QDB/
xz -z $QDB.tar
