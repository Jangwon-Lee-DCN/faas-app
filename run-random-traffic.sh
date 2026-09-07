#!/bin/bash

while true; do
  random_number=$((RANDOM % 20 + 1))
  ./load-test-ue.sh "$random_number" "$@"
  sleep $((RANDOM % 10 + 1))
done