#!/bin/sh
# expose_authtok: the password arrives on stdin (NUL-terminated).
IFS= read -r pw
[ "${pw%"$(printf '\0')"}" = "letmein" ]
