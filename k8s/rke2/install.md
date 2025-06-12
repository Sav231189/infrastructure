**Initial setup Ubuntu**:
<!-- Pre-Req For RKE2 Server -->
```bash
# 1) stop the software firewall
systemctl disable --now ufw

# 2) Run updates and upgrade and install packages
apt update
apt install nfs-common open-iscsi -y
apt upgrade -y

# 3) Automatic removal of unnecessary packages.
apt autoremove -y
```

**RKE2 Server Installation**:
```bash
# 1) Install RKE2 server
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -
# For specific RKE2 Server version
# curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=v1.26 INSTALL_RKE2_TYPE=server sh -

# 2) Enable and start RKE2 Server service
systemctl enable rke2-server.service
systemctl start rke2-server.service
# Alternatively, you can do this, which does the same thing
# systemctl enable --now rke2-server.service

# 3) Check is RKE2 Server is running
systemctl status rke2-server.service
```

**Setup Kubectl (on RKE2 Server)**:
```bash
# 1) Simlink all the things - kubectl
ln -s $(find /var/lib/rancher/rke2/data/ -name kubectl) /usr/local/bin/kubectl
# Alternatively, you can do this, which download the binary rather than using simlink. But note that you are downloading specific version of kubectl. Getting it from the RKE2 Server is a better option (aka simlink)
# curl -L# https://dl.k8s.io/release/v1.24.0/bin... -o /usr/local/bin/kubectl
# chmod 755 /usr/local/bin/kubectl
# 2) Add kubectl conf with persistence, as per Duane
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/usr/local/bin/:/var/lib/rancher/rke2/bin/" >> ~/.bashrc
source ~/.bashrc
# 3) Check if kubectl works
kubectl get node -o wide
# To watch as you start the RKE2 agent use this command.
# kubectl get node -o wide -w
```

**Get RKE2 Server IP address And Token (on RKE2 Server)**:
```bash
# 1) Get server IP address and copy it somewhere
ip addr | grep inet
# 2) Get server token and copy it somewhere
cat /var/lib/rancher/rke2/server/node-token
```

**RKE2 Agent Installation**:
```bash
# 1) Install RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sh -
# For specific RKE2 Server version
# curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=v1.26 INSTALL_RKE2_TYPE=agent sh -
# 2) Create config directory
mkdir -p /etc/rancher/rke2/
# 3) Create config.yaml file for RKE2 agent
nano /etc/rancher/rke2/config.yaml
# Enter text shown below.
server: https://#RKE2_SERVER_IP_ADDRESS#:9345
token: TOKEN_FROM_RKE2_SERVER#
# The #RANCHER_SERVER_IP_ADDRESS# is the ip address of RKE2 Server Install - Step 5
# The #TOKEN_FROM_RANCHER_SERVER# is the ip address of RKE2 Server Install - Step 6
# 4) Enable and start RKE2 Agent service
systemctl enable rke2-agent.service
systemctl start rke2-agent.service
# Alternatively, you can do this, which does the same thing
# systemctl enable --now rke2-agent.service
# systemctl status rke2-agent.service
# 5) Check is RKE2 Agent is running
systemctl status rke2-agent.service
# Run this command in RKE2 Server to check if RKE2 Agents are communicating with the RKE2 Server.
kubectl get node -o wide
# Run this command in RKE2 Server to check all pods status.
kubectl get pod -A
```
