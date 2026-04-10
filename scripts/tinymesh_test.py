import serial
import time

# --- CONFIGURATION ---
# On Windows, this is usually 'COM3', 'COM4', etc. 
# You can check this in 'Device Manager' under Ports.
PORT = 'COM3' 
BAUD = 19200  # Default TinyMesh baud rate

def run_validation():
    try:
        # Initialize Serial Connection
        ser = serial.Serial(PORT, BAUD, timeout=1)
        print(f"✅ Connected to {PORT} at {BAUD} baud.")
        print("🚦 Waiting for TinyMesh packets... (Press Ctrl+C to stop)")
        print("-" * 50)

        while True:
            if ser.in_waiting > 0:
                # Read whatever is in the buffer
                raw_data = ser.read(ser.in_waiting)
                
                # Convert to Hex for human reading
                hex_string = raw_data.hex(' ').upper()
                timestamp = time.strftime("%H:%M:%S")
                
                print(f"[{timestamp}] RAW HEX: {hex_string}")

                # TinyMesh packets usually start with 0x02 (STX)
                if raw_data[0] == 0x02:
                    print("   ✨ TINYMESH START BYTE DETECTED!")
                
            time.sleep(0.1)

    except serial.SerialException as e:
        print(f"❌ Error: Could not open {PORT}. Is the TTL converter plugged in?")
        print(f"   Details: {e}")
    except KeyboardInterrupt:
        print("\nStopping validation script...")
    finally:
        if 'ser' in locals() and ser.is_open:
            ser.close()
            print("🔌 Serial port closed.")

if __name__ == "__main__":
    run_validation()