#!/bin/sh
sudo apt update
sudo apt install apt-transport-https -y

# Install login manager and desktop environment
# source: https://cialu.net/how-to-solve-failed-to-start-session-with-lightdm-and-xfce/
sudo apt install -y \
  xfce4 \
  lightdm

echo "xfce4-session" > .xsession

# Update 50-unity-greeter to add user-session
cp /usr/share/lightdm/lightdm.conf.d/50-unity-greeter.conf{,.bak}
cat <<EOF > /usr/share/lightdm/lightdm.conf.d/50-unity-greeter.conf
[SeatDefaults]
greeter-session=unity-greeter
user-session=xfce
EOF

# Login to $DESKTOP_SESSION (which returns xfce)
cat <<EOF > /etc/lightdm/lightdm.conf.d/0-autologin.conf
[Seat:*]
autologin-session=xfce
autologin-user=vagrant
autologin-user-timeout=1
EOF

# Ignore "Use default" prompt when first booting into xfce
# source: https://mail.xfce.org/pipermail/xfce/2015-October/034685.html
cp /etc/xdg/xfce4/panel/default.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml

# Install vscode
# source: https://code.visualstudio.com/docs/setup/linux
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
rm packages.microsoft.gpg
sudo sh -c 'echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list'

# Install docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

# Install some of the base packages I like
sudo apt update
sudo apt install -y \
  code \
  terminator \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg-agent \
  software-properties-common \
  docker-ce \
  docker-ce-cli

# Setup the docker group
## add the group
sudo groupadd docker
sudo newgrp docker
## associate vagrant user with the docker group
sudo usermod -aG docker vagrant
sudo gpasswd -a vagrant docker
## enable docker
sudo systemctl enable docker
sudo systemctl start docker

# may need a reboot
reboot