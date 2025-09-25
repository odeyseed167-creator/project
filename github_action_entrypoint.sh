#!/bin/sh

sh -c "/root/.pub-cache/bin/linkcheck $INPUT_ARGUMENTS"
exit_code=$?
echo "exit_code=$exit_code" >>$GITHUB_OUTPUT
exit $exit_code