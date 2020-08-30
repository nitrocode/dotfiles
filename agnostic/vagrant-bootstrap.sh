sudo apt update
sudo apt install apt-transport-https -y

# Install login manager and desktop environment
# https://cialu.net/how-to-solve-failed-to-start-session-with-lightdm-and-xfce/
sudo apt install xfce4 lightdm -y
cp /usr/share/lightdm/lightdm.conf.d/50-unity-greeter.conf \
   /usr/share/lightdm/lightdm.conf.d/50-unity-greeter.conf.bak
cat <<EOF > /usr/share/lightdm/lightdm.conf.d/50-unity-greeter.conf
[SeatDefaults]
greeter-session=unity-greeter
user-session=xfce
EOF

# install vscode
# https://code.visualstudio.com/docs/setup/linux
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
sudo sh -c 'echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'

sudo apt update
sudo apt install code -y
