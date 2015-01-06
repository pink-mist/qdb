#!/bin/bash

FILES="bin/qdb.pl qdb.conf.sample README public/"
QDB="qdb-$1"

mkdir $QDB
cp -ar $FILES $QDB
tar cvf $QDB.tar $QDB/
xz -z $QDB.tar
