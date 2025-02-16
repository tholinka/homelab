#!/bin/sh
# cd to whatever folder you want to re-pull the stack, and run this, e.g.: ../up.sh
sudo docker compose -f docker-compose.yaml pull
sudo docker compose -f docker-compose.yaml up -d
