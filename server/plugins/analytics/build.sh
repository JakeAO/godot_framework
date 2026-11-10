#!/bin/sh
# Build the analytics Go plugin and install it into functions/ (see README.md).
set -eu
cd "$(dirname "$0")"
docker run --rm \
	-v "$PWD:/src" \
	-w /src \
	golang:1.25.5 \
	sh -c "go mod tidy && CGO_ENABLED=1 go build -trimpath -buildmode=plugin -o analytics.so ."
cp -f analytics.so ../../functions/analytics.so
echo "installed functions/analytics.so - restart nakama to load"
