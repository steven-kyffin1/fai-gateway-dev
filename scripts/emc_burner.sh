#!/bin/bash
echo "Starting EMC CPU and NVMe Stress Test..."

# Ensure 'bc' calculator is installed for the CPU stressor
if ! command -v bc &> /dev/null; then
    echo "Installing 'bc' for CPU math..."
    sudo apt-get install -y bc
fi

# Max out all CPU cores with endless math in the background
echo "Maxing out all CPU cores..."
for i in $(seq 1 $(nproc)); do
    while true; do echo "scale=5000; a(1)" | bc -l &> /dev/null; done &
done

# Continuously thrash the NVMe SSD to maximize PCIe bus noise
echo "Thrashing NVMe SSD on /opt/fai-storage..."
while true; do
    dd if=/dev/urandom of=/opt/fai-storage/emc_test.tmp bs=1M count=1000 conv=fdatasync 2>/dev/null
    rm -f /opt/fai-storage/emc_test.tmp
done
