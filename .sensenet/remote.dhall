-- Remote execution configuration for this project
-- Uses GCP gigafleet by default
let Remote = ../dhall/Remote.dhall

in Remote.gcpGigafleet
