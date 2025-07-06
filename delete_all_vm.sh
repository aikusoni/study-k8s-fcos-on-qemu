#!/bin/bash

# 특정 프로세스 확인
if pgrep -f "qemu-system-aarch64" > /dev/null; then
    echo "Turn off your vm before cleaning."
fi

echo "Do you want to delete all vm?"
select yn in "Yes" "No"; do
    case $yn in
        Yes)
            break
            ;;
        No)
            exit 0
            ;;
        *)
            echo "Error: Invalid selection. Please try again."
            ;;
    esac
done

echo "Cleaning..."
rm -rf temp
rm -rf machines
rm -rf wireguard-client-config/wireguard-vpn/*/using.lock
rm -rf .ssh
rm -rf loadbalancing

echo "Cleaning done."