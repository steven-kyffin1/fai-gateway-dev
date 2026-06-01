import time
import os
from smbus2 import SMBus

BUS_NUMBER = 6
LTC_ADDRESS = 0x09
REG_STATUS = 0x1C  # LTC3350 System Status Register

def is_on_backup(bus):
    try:
        # Read the 16-bit status register
        status = bus.read_word_data(LTC_ADDRESS, REG_STATUS)
        
        # Fix Endianness (swap the bytes to match the chip's native Big-Endian format)
        swapped_status = ((status & 0xFF) << 8) | (status >> 8)
        
        # In the LTC3350, bit 0 (0x1) is the step_up flag.
        # If it is 1, the capacitor is actively discharging to keep the system alive.
        return (swapped_status & 0x0001) != 0
    except Exception as e:
        # Ignore random I2C noise so we don't accidentally shut down
        return False 

def shutdown_host():
    print("CRITICAL: MAIN POWER LOST! SuperCAP backup engaged.")
    print("Initiating ZOMBIE-PROOF host shutdown...")
    
    # 1. Set a hardware wake-alarm 60 seconds into the future
    # If the power comes back (or never leaves), the RTC chip will physically 
    # short the power button to wake the board back up.
    os.system("echo 0 > /sys/class/rtc/rtc0/wakealarm")
    os.system("echo +60 > /sys/class/rtc/rtc0/wakealarm")
    
    # 2. Tell Linux to gracefully halt (stop the OS, unmount drives, but don't cut main power yet)
    os.system("dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.Halt boolean:true")
if __name__ == "__main__":
    print(f"🛡️ Starting SuperCAP UPS Watchdog (Production Mode) on I2C bus {BUS_NUMBER}...")
    
    # Debounce counter: Power must be gone for 5 full seconds to trigger shutdown
    backup_counter = 0
    TRIGGER_THRESHOLD = 20  
    
    try:
        with SMBus(BUS_NUMBER) as bus:
            while True:
                if is_on_backup(bus):
                    backup_counter += 1
                    print(f"WARNING: Operating on capacitor backup power! ({backup_counter}/{TRIGGER_THRESHOLD})")
                    
                    if backup_counter >= TRIGGER_THRESHOLD:
                        shutdown_host()
                        # Sleep for 60s so the script doesn't spam the shutdown command while the OS halts
                        time.sleep(60) 
                else:
                    if backup_counter > 0:
                        print("✅ Main power restored. Aborting shutdown sequence.")
                    backup_counter = 0
                
                time.sleep(1)
                
    except Exception as e:
        print(f"Fatal error initializing I2C bus {BUS_NUMBER}: {e}")