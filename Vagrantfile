# Multi-distro test harness for clientxcms-installer.
#
#   vagrant up debian12        # boot one box
#   vagrant ssh debian12       # then: sudo bash /vagrant/install.sh
#   vagrant destroy -f         # tear everything down
#
# The repo is mounted at /vagrant so you can run the local scripts. To test the
# local copy instead of the published one-liner, export GITHUB_BASE_URL to a
# raw URL of your fork, or source the local files directly.

Vagrant.configure("2") do |config|
  config.vm.provider "virtualbox" do |vb|
    vb.memory = 2048
    vb.cpus = 2
  end

  boxes = {
    "debian12"  => "debian/bookworm64",
    "ubuntu2204" => "ubuntu/jammy64",
    "rocky9"    => "rockylinux/9",
  }

  boxes.each do |name, box|
    config.vm.define name do |node|
      node.vm.box = box
      node.vm.hostname = "#{name}.clientxcms.test"
      node.vm.network "private_network", type: "dhcp"
    end
  end
end
