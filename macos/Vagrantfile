# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "AndrewDryga/vagrant-box-osx"
  config.vm.hostname = "dev"

  # config.vm.box_check_update = false

  # config.vm.network "forwarded_port", guest: 80, host: 8080

  # Create a private network, which allows host-only access to the machine
  # using a specific IP.
  config.vm.network "private_network", ip: "192.168.33.10"

  # did not work
  # config.vm.synced_folder ".", "/vagrant"
  # worked but permissions were off
  # config.vm.synced_folder ".", "/vagrant", type: "rsync"
  # worked but prompted for pass
  config.vm.synced_folder ".", "/vagrant", id: "core", :nfs => true, :mount_options => ['nolock,vers=3,udp,noatime']

  config.vm.provider "virtualbox" do |vb|
    # vb.name = "dev"
    # Display the VirtualBox GUI when booting the machine
    vb.gui = true
    # Customize the amount of memory on the VM:
    vb.memory = "8192"
    # set cpus
    vb.cpus = 4
  end
end
