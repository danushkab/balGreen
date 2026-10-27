#!/bin/bash

# ==========================================
# Edge Device Configuration
# ==========================================
PI_USER="root"               # Change to your Pi's username (e.g., root, orangepi)
PI_IP="192.168.1.60"            # Change to your Orange Pi's local network IP address
REMOTE_DIR="/opt/greenhouse"
JAR_PATH="target/bin/tds_middleware.jar"
SERVICE_NAME="greenhouse-middleware.service"

echo "===================================================="
echo "  Deploying Standard JAR to Orange Pi Zero 3 Edge   "
echo "===================================================="

# Verify the JAR exists locally
if [ ! -f "$JAR_PATH" ]; then
    echo "[ERROR] $JAR_PATH not found! Run 'bal build' locally first."
    exit 1
fi

# Step 1: Create the target directory on the Pi and transfer the JAR
echo "[INFO] Transferring JAR file to $PI_USER@$PI_IP:$REMOTE_DIR..."
ssh $PI_USER@$PI_IP "sudo mkdir -p $REMOTE_DIR && sudo chown -R $PI_USER:$PI_USER $REMOTE_DIR"
scp $JAR_PATH $PI_USER@$PI_IP:$REMOTE_DIR/

# Step 2: Generate the systemd service file directly on the Pi with strict JVM memory limits
echo "[INFO] Configuring systemd service with strict 128MB RAM ceiling..."
ssh $PI_USER@$PI_IP "sudo bash -c 'cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Greenhouse TDS Edge Middleware (Ballerina)
After=network.target

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$REMOTE_DIR
# Executes standard headless Java with aggressive memory constraints
ExecStart=/usr/bin/java -Xms32m -Xmx128m -Xss256k -jar $REMOTE_DIR/tds_middleware.jar
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'"

# Step 3: Enable and restart the service
echo "[INFO] Reloading daemon and starting the middleware..."
ssh $PI_USER@$PI_IP "sudo systemctl daemon-reload"
ssh $PI_USER@$PI_IP "sudo systemctl enable $SERVICE_NAME"
ssh $PI_USER@$PI_IP "sudo systemctl restart $SERVICE_NAME"
echo "[INFO] Fetching service status..."
ssh $PI_USER@$PI_IP "sudo systemctl status $SERVICE_NAME --no-pager"

echo "[SUCCESS] Deployment complete! The middleware is now running in the background."